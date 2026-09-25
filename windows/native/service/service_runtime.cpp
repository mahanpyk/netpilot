#include "service_runtime.h"

#include <sddl.h>
#include <winsvc.h>
#include <fwpmu.h>

#include <algorithm>
#include <cstring>
#include <filesystem>
#include <sstream>
#include <unordered_map>
#include <iomanip>

#include "../common/driver_control.h"
#include "browser_reconnect.h"

namespace {

bool ReadAll(HANDLE pipe, void* bytes, DWORD size) {
  auto* cursor = static_cast<uint8_t*>(bytes);
  while (size) {
    DWORD read = 0;
    if (!ReadFile(pipe, cursor, size, &read, nullptr) || read == 0) return false;
    cursor += read;
    size -= read;
  }
  return true;
}

bool WriteAll(HANDLE pipe, const void* bytes, DWORD size) {
  const auto* cursor = static_cast<const uint8_t*>(bytes);
  while (size) {
    DWORD written = 0;
    if (!WriteFile(pipe, cursor, size, &written, nullptr) || written == 0)
      return false;
    cursor += written;
    size -= written;
  }
  return true;
}

bool DriverReady() {
  HANDLE device = CreateFileW(L"\\\\.\\NetPilotWfp", GENERIC_READ, 0, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (device == INVALID_HANDLE_VALUE) return false;
  CloseHandle(device);
  return true;
}

bool ConfigureDriverProxyProcess(std::string* error) {
  HANDLE device = CreateFileW(L"\\\\.\\NetPilotWfp",
                              GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (device == INVALID_HANDLE_VALUE) {
    *error = "WFP Driver is not installed or not running";
    return false;
  }
  NetPilotProxyProcessConfig config{kNetPilotProxyProcessConfigVersion,
                                    GetCurrentProcessId()};
  DWORD returned = 0;
  const bool configured =
      DeviceIoControl(device, IOCTL_NETPILOT_SET_PROXY_PID, &config,
                      sizeof(config), nullptr, 0, &returned, nullptr) != FALSE;
  const DWORD code = configured ? ERROR_SUCCESS : GetLastError();
  CloseHandle(device);
  if (!configured) {
    *error = "could not register NetPilot Service with WFP Driver (" +
             std::to_string(code) + ")";
  }
  return configured;
}

bool TestModeEnabled() {
  struct CodeIntegrityInformation {
    ULONG Length;
    ULONG Options;
  } information{sizeof(CodeIntegrityInformation), 0};
  using Query = LONG(WINAPI*)(ULONG, PVOID, ULONG, PULONG);
  Query query = nullptr;
  const auto procedure =
      GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQuerySystemInformation");
  static_assert(sizeof(query) == sizeof(procedure));
  std::memcpy(&query, &procedure, sizeof(query));
  constexpr ULONG kSystemCodeIntegrityInformation = 103;
  constexpr ULONG kTestSign = 0x02;
  return query && query(kSystemCodeIntegrityInformation, &information,
                        sizeof(information), nullptr) >= 0 &&
         (information.Options & kTestSign) != 0;
}

std::string ProcessPath(DWORD process_id) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                               process_id);
  if (!process) return {};
  std::wstring path(32768, L'\0');
  DWORD size = static_cast<DWORD>(path.size());
  if (!QueryFullProcessImageNameW(process, 0, path.data(), &size)) size = 0;
  CloseHandle(process);
  path.resize(size);
  const int bytes = WideCharToMultiByte(CP_UTF8, 0, path.data(), size, nullptr,
                                        0, nullptr, nullptr);
  std::string output(bytes, '\0');
  if (bytes)
    WideCharToMultiByte(CP_UTF8, 0, path.data(), size, output.data(), bytes,
                        nullptr, nullptr);
  return output;
}

std::filesystem::path ModuleDirectory() {
  std::wstring path(32768, L'\0');
  const DWORD size = GetModuleFileNameW(
      nullptr, path.data(), static_cast<DWORD>(path.size()));
  path.resize(size);
  std::error_code error;
  return std::filesystem::weakly_canonical(
      std::filesystem::path(path).parent_path(), error);
}

std::wstring Wide(const std::string& value) {
  const int input_size = static_cast<int>(value.size());
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.data(), input_size,
                                       nullptr, 0);
  std::wstring output(size, L'\0');
  if (size)
    MultiByteToWideChar(CP_UTF8, 0, value.data(), input_size, output.data(),
                        size);
  return output;
}

std::string AppIdHex(const std::wstring& path) {
  FWP_BYTE_BLOB* blob = nullptr;
  if (FwpmGetAppIdFromFileName0(path.c_str(), &blob) != ERROR_SUCCESS || !blob)
    return {};
  std::ostringstream stream;
  stream << std::hex << std::setfill('0');
  for (UINT32 i = 0; i < blob->size; ++i)
    stream << std::setw(2) << static_cast<unsigned>(blob->data[i]);
  FwpmFreeMemory0(reinterpret_cast<void**>(&blob));
  return stream.str();
}

}  // namespace

ServiceRuntime::ServiceRuntime() : wfp_(&diagnostics_), relay_(&diagnostics_) {}
ServiceRuntime::~ServiceRuntime() { Stop(); }

bool ServiceRuntime::Initialize(std::string* error) {
  routes_.Cleanup();
  if (!ConfigureDriverProxyProcess(error) || !wfp_.Initialize(error) ||
      !relay_.Start(error))
    return false;
  NotifyIpInterfaceChange(AF_INET, OnInterfaceChanged, this, FALSE,
                          &interface_notification_);
  diagnostics_.Log("Windows Service started; WFP engine ready");
  return true;
}

void ServiceRuntime::Run(HANDLE stop_event) {
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  ConvertStringSecurityDescriptorToSecurityDescriptorW(
      L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)", SDDL_REVISION_1,
      &descriptor, nullptr);
  SECURITY_ATTRIBUTES attributes{sizeof(attributes), descriptor, FALSE};
  while (!stopping_) {
    HANDLE pipe = CreateNamedPipeW(
        netpilot::kPipeName, PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        16, netpilot::kMaxFrameBytes, netpilot::kMaxFrameBytes, 0,
        descriptor ? &attributes : nullptr);
    if (pipe == INVALID_HANDLE_VALUE) break;
    const bool connected = ConnectNamedPipe(pipe, nullptr) ||
                           GetLastError() == ERROR_PIPE_CONNECTED;
    if (connected && !stopping_) ServeClient(pipe);
    FlushFileBuffers(pipe);
    DisconnectNamedPipe(pipe);
    CloseHandle(pipe);
    if (WaitForSingleObject(stop_event, 0) == WAIT_OBJECT_0) break;
  }
  if (descriptor) LocalFree(descriptor);
}

void ServiceRuntime::Stop() {
  if (stopping_.exchange(true)) return;
  if (interface_notification_) {
    CancelMibChangeNotify2(interface_notification_);
    interface_notification_ = nullptr;
  }
  wfp_.Clear();
  relay_.Stop();
  routes_.Cleanup();
  HANDLE wake = CreateFileW(netpilot::kPipeName, GENERIC_READ | GENERIC_WRITE,
                            0, nullptr, OPEN_EXISTING, 0, nullptr);
  if (wake != INVALID_HANDLE_VALUE) CloseHandle(wake);
  diagnostics_.Log("Windows Service stopped; filters and routes removed");
}

bool ServiceRuntime::AuthorizeClient(HANDLE pipe, std::string* error) const {
  ULONG process_id = 0;
  if (!GetNamedPipeClientProcessId(pipe, &process_id)) {
    *error = "could not identify named-pipe client";
    return false;
  }
  const auto path = ProcessPath(process_id);
  std::filesystem::path executable = Wide(path);
  if (_wcsicmp(executable.filename().c_str(), L"netpilot_desktop.exe") != 0 &&
      _wcsicmp(executable.filename().c_str(), L"NetPilotMaintenance.exe") != 0) {
    *error = "named-pipe client is not NetPilot Desktop";
    return false;
  }
  std::error_code canonical_error;
  const auto parent = std::filesystem::weakly_canonical(
      executable.parent_path(), canonical_error);
  if (canonical_error ||
      _wcsicmp(parent.c_str(), ModuleDirectory().c_str()) != 0) {
    *error = "named-pipe client is outside the NetPilot installation directory";
    return false;
  }
  return true;
}

bool ServiceRuntime::ServeClient(HANDLE pipe) {
  std::string authorization_error;
  if (!AuthorizeClient(pipe, &authorization_error)) {
    diagnostics_.Log("Rejected service client: " + authorization_error);
    return false;
  }
  netpilot::FrameHeader header;
  if (!ReadAll(pipe, &header, sizeof(header)) ||
      header.magic != netpilot::kProtocolMagic ||
      header.version != netpilot::kProtocolVersion ||
      header.payload_size > netpilot::kMaxFrameBytes) {
    diagnostics_.Log("Rejected malformed service frame");
    return false;
  }
  std::vector<uint8_t> payload(header.payload_size);
  if (header.payload_size &&
      !ReadAll(pipe, payload.data(), header.payload_size)) {
    return false;
  }
  ULONG client_pid = 0;
  DWORD client_session = 0xffffffffu;
  if (GetNamedPipeClientProcessId(pipe, &client_pid))
    ProcessIdToSessionId(client_pid, &client_session);
  const auto response = Dispatch(
      static_cast<netpilot::Operation>(header.operation), payload,
      client_session);
  header.payload_size = static_cast<uint32_t>(response.size());
  return WriteAll(pipe, &header, sizeof(header)) &&
         (response.empty() ||
          WriteAll(pipe, response.data(), header.payload_size));
}

std::vector<uint8_t> ServiceRuntime::Dispatch(
    netpilot::Operation operation, const std::vector<uint8_t>& payload,
    uint32_t client_session) {
  netpilot::BufferWriter writer;
  if (operation == netpilot::Operation::kPing ||
      operation == netpilot::Operation::kStatus) {
    netpilot::EncodeStatus(Status(), &writer);
  } else if (operation == netpilot::Operation::kReconcileRoutes) {
    netpilot::BufferReader reader(payload);
    std::vector<netpilot::RouteSpec> desired;
    netpilot::ReconcileResult result;
    if (!netpilot::DecodeRoutes(&reader, &desired)) {
      result.errors.push_back("invalid route request");
    } else {
      std::scoped_lock lock(mutex_);
      result = routes_.Reconcile(desired);
      if (!result.connection_reset_destinations.empty()) {
        std::string warning;
        result.restarted_processes = BrowserReconnect::Reconnect(
            result.connection_reset_destinations, client_session, &warning);
        if (!warning.empty()) diagnostics_.Log("[NetPilot] " + warning);
        for (const auto& process : result.restarted_processes)
          diagnostics_.Log("[NetPilot] Reconnected browser networking: " +
                           process.name + " (PID " +
                           std::to_string(process.pid) + ")");
      }
      for (const auto& check : result.route_checks)
        diagnostics_.Log("[NetPilot] Route check " + check.destination +
                         " expected=" + check.expected_interface +
                         " actual=" + check.actual_interface +
                         (check.verified ? " verified" : " FAILED " + check.message));
      diagnostics_.Log("Route reconcile desired=" +
                       std::to_string(desired.size()) + " added=" +
                       std::to_string(result.added) + " removed=" +
                       std::to_string(result.removed));
    }
    netpilot::EncodeReconcileResult(result, &writer);
  } else if (operation == netpilot::Operation::kApplyAppRouting) {
    netpilot::BufferReader reader(payload);
    bool master = false;
    std::string hash;
    std::vector<netpilot::AppRuleSpec> rules;
    std::string error;
    if (!netpilot::DecodeAppRules(&reader, &master, &hash, &rules) ||
        !ValidateRules(rules, &error)) {
      netpilot::EncodeStatus(Status(error.empty() ? "invalid app rules" : error),
                             &writer);
    } else {
      std::scoped_lock lock(mutex_);
      relay_.Configure(rules);
      if (wfp_.Apply(master, hash, rules, &error)) {
        relay_.RestartFlows();
        master_enabled_ = master;
        applied_hash_ = hash;
        app_rules_ = std::move(rules);
        proxy_running_ = master;
        diagnostics_.Log("[NetPilot App Routing] applied hash=" + hash +
                         " rules=" + std::to_string(app_rules_.size()));
      } else {
        proxy_running_ = false;
        diagnostics_.Log("[NetPilot App Routing] apply failed: " + error);
      }
      netpilot::EncodeStatus(Status(error), &writer);
    }
  } else if (operation == netpilot::Operation::kDiagnostics) {
    const auto lines = diagnostics_.Snapshot();
    writer.WriteU32(static_cast<uint32_t>(lines.size()));
    for (const auto& line : lines) writer.WriteString(line);
  } else if (operation == netpilot::Operation::kCleanup) {
    std::scoped_lock lock(mutex_);
    wfp_.Clear();
    routes_.Cleanup();
    netpilot::EncodeStatus(Status("system state cleaned"), &writer);
  } else {
    netpilot::EncodeStatus(Status("unsupported service operation"), &writer);
  }
  return writer.bytes();
}

netpilot::ServiceStatus ServiceRuntime::Status(
    const std::string& message) const {
  netpilot::ServiceStatus status;
  status.service_ready = true;
  status.driver_ready = DriverReady();
  status.engine_ready = wfp_.ready() && status.driver_ready;
  status.proxy_running = proxy_running_ && status.engine_ready && relay_.running();
  status.test_mode = TestModeEnabled();
  status.applied_hash = applied_hash_;
  for (const auto& metric : relay_.Metrics()) {
    status.active_flows += metric.active_flows;
    status.bytes_in += metric.bytes_in;
    status.bytes_out += metric.bytes_out;
    status.rule_metrics.push_back({metric.id, metric.active_flows,
                                   metric.bytes_in, metric.bytes_out,
                                   metric.last_error});
  }
  status.message = message.empty()
                       ? status.engine_ready
                             ? "Windows Service and WFP Driver are ready"
                             : "WFP Driver is not installed or not running"
                       : message;
  return status;
}

bool ServiceRuntime::ValidateRules(
    const std::vector<netpilot::AppRuleSpec>& rules, std::string* error) const {
  std::unordered_map<std::string, std::string> owners;
  for (const auto& rule : rules) {
    if (!netpilot::IsValidAppRule(rule, error)) return false;
    if (!rule.enabled) continue;
    for (const auto& executable : rule.executables) {
      const auto requested_path = std::filesystem::path(Wide(executable.path));
      std::error_code path_error;
      const auto canonical =
          std::filesystem::weakly_canonical(requested_path, path_error);
      if (path_error || !std::filesystem::is_regular_file(canonical) ||
          _wcsicmp(canonical.c_str(), requested_path.c_str()) != 0 ||
          AppIdHex(canonical.wstring()) != executable.app_id) {
        *error = "executable path or WFP App ID failed service validation";
        return false;
      }
      const auto executable_wide_path = Wide(executable.path);
      const auto name = std::filesystem::path(executable_wide_path).filename();
      if (_wcsicmp(name.c_str(), L"NetPilotService.exe") == 0 ||
          _wcsicmp(name.c_str(), L"netpilot_desktop.exe") == 0 ||
          _wcsicmp(name.c_str(), L"NetPilotMaintenance.exe") == 0) {
        *error = "NetPilot components cannot be selected for app routing";
        return false;
      }
      std::string key = executable.app_id;
      std::transform(key.begin(), key.end(), key.begin(),
                     [](unsigned char value) {
                       return static_cast<char>(std::tolower(value));
                     });
      const auto found = owners.find(key);
      if (found != owners.end() && found->second != rule.interface_luid) {
        *error = "WFP App ID overlaps rules on different adapters";
        return false;
      }
      owners[key] = rule.interface_luid;
    }
  }
  return true;
}

void WINAPI ServiceRuntime::OnInterfaceChanged(PVOID context,
                                                PMIB_IPINTERFACE_ROW,
                                                MIB_NOTIFICATION_TYPE) {
  auto* runtime = static_cast<ServiceRuntime*>(context);
  if (runtime && !runtime->stopping_) runtime->ReapplyForNetworkChange();
}

void ServiceRuntime::ReapplyForNetworkChange() {
  std::scoped_lock lock(mutex_);
  if (!master_enabled_) return;
  std::string error;
  if (!wfp_.Apply(master_enabled_, applied_hash_, app_rules_, &error)) {
    diagnostics_.Log("[NetPilot App Routing] network-change apply failed: " +
                     error);
  } else {
    diagnostics_.Log(
        "[NetPilot App Routing] rebuilt filters after interface change");
  }
}
