#include "browser_reconnect.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <wbemidl.h>

#include <algorithm>
#include <cwctype>
#include <filesystem>
#include <set>
#include <vector>

namespace {

struct Cidr {
  uint32_t network;
  uint32_t mask;
};

std::vector<Cidr> ParseCidrs(const std::vector<std::string>& values) {
  std::vector<Cidr> cidrs;
  for (const auto& value : values) {
    const auto slash = value.find('/');
    if (slash == std::string::npos) continue;
    IN_ADDR address{};
    if (InetPtonA(AF_INET, value.substr(0, slash).c_str(), &address) != 1)
      continue;
    try {
      const int length = std::stoi(value.substr(slash + 1));
      if (length < 0 || length > 32) continue;
      const uint32_t mask = length == 0 ? 0 : 0xffffffffu << (32 - length);
      cidrs.push_back({ntohl(address.S_un.S_addr) & mask, mask});
    } catch (...) {
      continue;
    }
  }
  return cidrs;
}

bool Contains(const std::vector<Cidr>& cidrs, DWORD network_order_address) {
  const uint32_t address = ntohl(network_order_address);
  return std::any_of(cidrs.begin(), cidrs.end(), [&](const Cidr& cidr) {
    return (address & cidr.mask) == cidr.network;
  });
}

std::set<DWORD> TcpOwners(const std::vector<Cidr>& cidrs) {
  DWORD size = 0;
  GetExtendedTcpTable(nullptr, &size, FALSE, AF_INET,
                      TCP_TABLE_OWNER_PID_CONNECTIONS, 0);
  if (size == 0 || size > 32 * 1024 * 1024) return {};
  std::vector<uint8_t> buffer(size);
  if (GetExtendedTcpTable(buffer.data(), &size, FALSE, AF_INET,
                          TCP_TABLE_OWNER_PID_CONNECTIONS, 0) != NO_ERROR)
    return {};
  const auto* table = reinterpret_cast<const MIB_TCPTABLE_OWNER_PID*>(buffer.data());
  std::set<DWORD> owners;
  for (DWORD index = 0; index < table->dwNumEntries; ++index) {
    const auto& row = table->table[index];
    if (row.dwOwningPid > 1 && Contains(cidrs, row.dwRemoteAddr))
      owners.insert(row.dwOwningPid);
  }
  return owners;
}

std::set<DWORD> UdpOwners() {
  DWORD size = 0;
  GetExtendedUdpTable(nullptr, &size, FALSE, AF_INET, UDP_TABLE_OWNER_PID, 0);
  if (size == 0 || size > 32 * 1024 * 1024) return {};
  std::vector<uint8_t> buffer(size);
  if (GetExtendedUdpTable(buffer.data(), &size, FALSE, AF_INET,
                          UDP_TABLE_OWNER_PID, 0) != NO_ERROR)
    return {};
  const auto* table = reinterpret_cast<const MIB_UDPTABLE_OWNER_PID*>(buffer.data());
  std::set<DWORD> owners;
  for (DWORD index = 0; index < table->dwNumEntries; ++index) {
    if (table->table[index].dwOwningPid > 1)
      owners.insert(table->table[index].dwOwningPid);
  }
  return owners;
}

bool IsKnownChromiumExecutable(const std::wstring& path) {
  std::wstring name = std::filesystem::path(path).filename().wstring();
  std::transform(name.begin(), name.end(), name.begin(),
                 [](wchar_t character) {
                   return static_cast<wchar_t>(std::towlower(character));
                 });
  return name == L"chrome.exe" || name == L"msedge.exe" ||
         name == L"brave.exe" || name == L"opera.exe" ||
         name == L"chromium.exe" || name == L"vivaldi.exe";
}

std::wstring CommandLine(IWbemServices* service, DWORD pid) {
  const std::wstring query = L"SELECT CommandLine FROM Win32_Process WHERE ProcessId = " +
                             std::to_wstring(pid);
  BSTR language = SysAllocString(L"WQL");
  BSTR query_bstr = SysAllocString(query.c_str());
  IEnumWbemClassObject* enumerator = nullptr;
  const HRESULT status = service->ExecQuery(
      language, query_bstr,
      WBEM_FLAG_FORWARD_ONLY | WBEM_FLAG_RETURN_IMMEDIATELY, nullptr,
      &enumerator);
  SysFreeString(language);
  SysFreeString(query_bstr);
  if (FAILED(status) || !enumerator) return {};
  IWbemClassObject* object = nullptr;
  ULONG returned = 0;
  std::wstring command;
  if (enumerator->Next(3000, 1, &object, &returned) == WBEM_S_NO_ERROR &&
      returned == 1 && object) {
    VARIANT value;
    VariantInit(&value);
    if (SUCCEEDED(object->Get(L"CommandLine", 0, &value, nullptr, nullptr)) &&
        value.vt == VT_BSTR && value.bstrVal)
      command = value.bstrVal;
    VariantClear(&value);
    object->Release();
  }
  enumerator->Release();
  return command;
}

}  // namespace

std::vector<netpilot::ReconcileResult::RestartedProcess>
BrowserReconnect::Reconnect(const std::vector<std::string>& destinations,
                            uint32_t client_session, std::string* warning) {
  std::vector<netpilot::ReconcileResult::RestartedProcess> restarted;
  const auto cidrs = ParseCidrs(destinations);
  if (cidrs.empty()) return restarted;
  auto candidates = TcpOwners(cidrs);
  const auto udp = UdpOwners();
  candidates.insert(udp.begin(), udp.end());
  if (candidates.empty()) return restarted;

  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized)) {
    *warning = "browser refresh skipped: WMI initialization failed";
    return restarted;
  }
  IWbemLocator* locator = nullptr;
  IWbemServices* service = nullptr;
  HRESULT status = CoCreateInstance(CLSID_WbemLocator, nullptr,
                                    CLSCTX_INPROC_SERVER, IID_IWbemLocator,
                                    reinterpret_cast<void**>(&locator));
  if (SUCCEEDED(status)) {
    BSTR name_space = SysAllocString(L"ROOT\\CIMV2");
    status = locator->ConnectServer(name_space, nullptr, nullptr, nullptr,
                                    0, nullptr, nullptr, &service);
    SysFreeString(name_space);
  }
  if (SUCCEEDED(status) && service) {
    status = CoSetProxyBlanket(service, RPC_C_AUTHN_WINNT, RPC_C_AUTHZ_NONE,
                              nullptr, RPC_C_AUTHN_LEVEL_CALL,
                              RPC_C_IMP_LEVEL_IMPERSONATE, nullptr, EOAC_NONE);
  }
  if (FAILED(status) || !service) {
    *warning = "browser refresh skipped: WMI process query unavailable";
  } else {
    for (const DWORD pid : candidates) {
      DWORD session = 0;
      if (!ProcessIdToSessionId(pid, &session) || session != client_session)
        continue;
      HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION |
                                       PROCESS_TERMINATE,
                                   FALSE, pid);
      if (!process) continue;
      std::wstring path(32768, L'\0');
      DWORD size = static_cast<DWORD>(path.size());
      if (QueryFullProcessImageNameW(process, 0, path.data(), &size)) {
        path.resize(size);
        if (IsKnownChromiumExecutable(path)) {
          const auto command = CommandLine(service, pid);
          if (command.find(L"--utility-sub-type=network.mojom.NetworkService") !=
                  std::wstring::npos &&
              TerminateProcess(process, 0)) {
            restarted.push_back({pid, "Chromium Network Service"});
          }
        }
      }
      CloseHandle(process);
    }
  }
  if (service) service->Release();
  if (locator) locator->Release();
  CoUninitialize();
  return restarted;
}
