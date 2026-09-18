#include <windows.h>
#include <newdev.h>
#include <shlobj.h>
#include <winsvc.h>

#include <filesystem>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

#include "../common/netpilot_protocol.h"

namespace {

constexpr wchar_t kServiceName[] = L"NetPilotService";

bool IsElevated() {
  BOOL elevated = FALSE;
  HANDLE token = nullptr;
  TOKEN_ELEVATION elevation{};
  DWORD size = 0;
  if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    if (GetTokenInformation(token, TokenElevation, &elevation,
                            sizeof(elevation), &size))
      elevated = elevation.TokenIsElevated;
    CloseHandle(token);
  }
  return elevated != FALSE;
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

std::filesystem::path ExecutableDirectory() {
  std::wstring value(32768, L'\0');
  const DWORD size = GetModuleFileNameW(
      nullptr, value.data(), static_cast<DWORD>(value.size()));
  value.resize(size);
  return std::filesystem::path(value).parent_path();
}

bool InstallService(const std::filesystem::path& binary, bool allow_pending) {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_ALL_ACCESS);
  if (!manager) return false;
  const auto quoted = L"\"" + binary.wstring() + L"\"";
  SC_HANDLE service = CreateServiceW(
      manager, kServiceName, L"NetPilot Windows Service", SERVICE_ALL_ACCESS,
      SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START, SERVICE_ERROR_NORMAL,
      quoted.c_str(), nullptr, nullptr, nullptr, L"LocalSystem", nullptr);
  if (!service && GetLastError() == ERROR_SERVICE_EXISTS)
    service = OpenServiceW(manager, kServiceName, SERVICE_ALL_ACCESS);
  if (!service) {
    CloseServiceHandle(manager);
    return false;
  }
  ChangeServiceConfigW(service, SERVICE_NO_CHANGE, SERVICE_AUTO_START,
                       SERVICE_NO_CHANGE, quoted.c_str(), nullptr, nullptr,
                       nullptr, L"LocalSystem", nullptr,
                       L"NetPilot Windows Service");
  SC_ACTION actions[] = {{SC_ACTION_RESTART, 5000},
                         {SC_ACTION_RESTART, 15000},
                         {SC_ACTION_RESTART, 60000}};
  SERVICE_FAILURE_ACTIONSW recovery{};
  recovery.dwResetPeriod = 86400;
  recovery.cActions = 3;
  recovery.lpsaActions = actions;
  ChangeServiceConfig2W(service, SERVICE_CONFIG_FAILURE_ACTIONS, &recovery);
  const bool started = StartServiceW(service, 0, nullptr) != FALSE ||
                       GetLastError() == ERROR_SERVICE_ALREADY_RUNNING;
  CloseServiceHandle(service);
  CloseServiceHandle(manager);
  return started || allow_pending;
}

void StopAndDeleteService() {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_ALL_ACCESS);
  if (!manager) return;
  SC_HANDLE service = OpenServiceW(manager, kServiceName,
                                   SERVICE_STOP | DELETE | SERVICE_QUERY_STATUS);
  if (service) {
    SERVICE_STATUS status{};
    ControlService(service, SERVICE_CONTROL_STOP, &status);
    DeleteService(service);
    CloseServiceHandle(service);
  }
  CloseServiceHandle(manager);
}

void RequestCleanup() {
  if (!WaitNamedPipeW(netpilot::kPipeName, 2000)) return;
  HANDLE pipe = CreateFileW(netpilot::kPipeName, GENERIC_READ | GENERIC_WRITE,
                            0, nullptr, OPEN_EXISTING, 0, nullptr);
  if (pipe == INVALID_HANDLE_VALUE) return;
  netpilot::FrameHeader header;
  header.operation = static_cast<uint16_t>(netpilot::Operation::kCleanup);
  DWORD transferred = 0;
  WriteFile(pipe, &header, sizeof(header), &transferred, nullptr);
  ReadFile(pipe, &header, sizeof(header), &transferred, nullptr);
  if (header.payload_size && header.payload_size <= netpilot::kMaxFrameBytes) {
    std::vector<uint8_t> ignored(header.payload_size);
    ReadFile(pipe, ignored.data(), header.payload_size, &transferred, nullptr);
  }
  CloseHandle(pipe);
}

void RemoveSystemState() {
  PWSTR raw = nullptr;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_ProgramData, 0, nullptr, &raw))) {
    std::error_code ignored;
    std::filesystem::remove_all(std::filesystem::path(raw) / L"NetPilot",
                                ignored);
    CoTaskMemFree(raw);
  }
}

bool InstallDriver(const std::filesystem::path& inf, bool* reboot) {
  using InstallDriver = BOOL(WINAPI*)(HWND, LPCWSTR, DWORD, PBOOL);
  HMODULE newdev = LoadLibraryW(L"newdev.dll");
  if (!newdev) return false;
  InstallDriver install = nullptr;
  const auto procedure = GetProcAddress(newdev, "DiInstallDriverW");
  static_assert(sizeof(install) == sizeof(procedure));
  std::memcpy(&install, &procedure, sizeof(install));
  if (!install) {
    FreeLibrary(newdev);
    return false;
  }
  BOOL restart = FALSE;
  const BOOL result = install(nullptr, inf.c_str(), DIIRFLAG_FORCE_INF, &restart);
  FreeLibrary(newdev);
  *reboot = restart != FALSE;
  return result != FALSE;
}

bool StartKernelDriver() {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (!manager) return false;
  SC_HANDLE service = OpenServiceW(manager, L"NetPilotWfp",
                                   SERVICE_START | SERVICE_QUERY_STATUS);
  if (!service) {
    CloseServiceHandle(manager);
    return false;
  }
  const bool started = StartServiceW(service, 0, nullptr) != FALSE ||
                       GetLastError() == ERROR_SERVICE_ALREADY_RUNNING;
  CloseServiceHandle(service);
  CloseServiceHandle(manager);
  return started;
}

bool RemoveDriver(const std::filesystem::path& inf, bool* reboot) {
  using UninstallDriver = BOOL(WINAPI*)(HWND, LPCWSTR, DWORD, PBOOL);
  HMODULE newdev = LoadLibraryW(L"newdev.dll");
  if (!newdev) return false;
  UninstallDriver uninstall = nullptr;
  const auto procedure = GetProcAddress(newdev, "DiUninstallDriverW");
  static_assert(sizeof(uninstall) == sizeof(procedure));
  std::memcpy(&uninstall, &procedure, sizeof(uninstall));
  if (!uninstall) {
    FreeLibrary(newdev);
    return false;
  }
  BOOL restart = FALSE;
  const BOOL result = uninstall(nullptr, inf.c_str(), 0, &restart);
  const DWORD error = GetLastError();
  FreeLibrary(newdev);
  *reboot = restart != FALSE;
  return result != FALSE || error == ERROR_NOT_FOUND;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (!IsElevated()) {
    std::wcerr << L"NetPilot maintenance requires elevation.\n";
    return ERROR_ELEVATION_REQUIRED;
  }
  if (argc != 2) return ERROR_BAD_ARGUMENTS;
  const auto directory = ExecutableDirectory();
  const auto service = directory / L"NetPilotService.exe";
  const auto inf = directory / L"driver" / L"NetPilotWfp.inf";
  const std::wstring operation = argv[1];
  bool reboot = false;
  if (operation == L"install" || operation == L"repair") {
    if (!TestModeEnabled()) {
      std::wcerr << L"NetPilot's development driver requires Windows Test "
                    L"Mode. Enable Test Mode and reboot before installation.\n";
      return ERROR_DRIVER_BLOCKED;
    }
    if (!InstallDriver(inf, &reboot) || (!reboot && !StartKernelDriver()) ||
        !InstallService(service, reboot))
      return 1;
  } else if (operation == L"remove") {
    RequestCleanup();
    StopAndDeleteService();
    RemoveDriver(inf, &reboot);
    RemoveSystemState();
  } else {
    return ERROR_BAD_ARGUMENTS;
  }
  return reboot ? ERROR_SUCCESS_REBOOT_REQUIRED : ERROR_SUCCESS;
}
