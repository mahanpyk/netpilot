#include <windows.h>

#include <memory>
#include <string>

#include "service_runtime.h"

namespace {

SERVICE_STATUS_HANDLE status_handle = nullptr;
SERVICE_STATUS service_status{};
HANDLE stop_event = nullptr;
ServiceRuntime* runtime = nullptr;

void SetState(DWORD state, DWORD error = NO_ERROR) {
  service_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
  service_status.dwCurrentState = state;
  service_status.dwWin32ExitCode = error;
  service_status.dwControlsAccepted =
      state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN
                               : 0;
  SetServiceStatus(status_handle, &service_status);
}

DWORD WINAPI ControlHandler(DWORD control, DWORD, void*, void*) {
  if (control == SERVICE_CONTROL_STOP || control == SERVICE_CONTROL_SHUTDOWN) {
    SetState(SERVICE_STOP_PENDING);
    if (runtime) runtime->Stop();
    SetEvent(stop_event);
  }
  return NO_ERROR;
}

void WINAPI ServiceMain(DWORD, wchar_t**) {
  status_handle = RegisterServiceCtrlHandlerExW(L"NetPilotService",
                                                 ControlHandler, nullptr);
  if (!status_handle) return;
  SetState(SERVICE_START_PENDING);
  stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  ServiceRuntime instance;
  runtime = &instance;
  std::string error;
  if (!stop_event || !instance.Initialize(&error)) {
    SetState(SERVICE_STOPPED, ERROR_SERVICE_SPECIFIC_ERROR);
    runtime = nullptr;
    return;
  }
  SetState(SERVICE_RUNNING);
  instance.Run(stop_event);
  runtime = nullptr;
  SetState(SERVICE_STOPPED);
  CloseHandle(stop_event);
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc > 1 && std::wstring(argv[1]) == L"--console") {
    HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    ServiceRuntime instance;
    std::string error;
    if (!instance.Initialize(&error)) return 2;
    instance.Run(event);
    CloseHandle(event);
    return 0;
  }
  SERVICE_TABLE_ENTRYW table[] = {
      {const_cast<wchar_t*>(L"NetPilotService"), ServiceMain}, {nullptr, nullptr}};
  return StartServiceCtrlDispatcherW(table) ? 0 : 1;
}
