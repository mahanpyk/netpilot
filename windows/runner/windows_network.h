#ifndef RUNNER_WINDOWS_NETWORK_H_
#define RUNNER_WINDOWS_NETWORK_H_

#include <functional>
#include <cstdint>
#include <string>
#include <vector>

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <netioapi.h>

struct WindowsAdapterInfo {
  std::string id;
  std::string native_id;
  std::string name;
  std::string interface_name;
  std::string kind;
  std::vector<std::string> ipv4_addresses;
  std::string gateway;
  std::vector<std::string> dns_servers;
  bool is_default_route = false;
  bool is_active = false;
  uint32_t interface_index = 0;
};

class WindowsNetworkInventory {
 public:
  using ChangeCallback = std::function<void()>;

  WindowsNetworkInventory();
  ~WindowsNetworkInventory();

  std::vector<WindowsAdapterInfo> List(std::string* error) const;
  std::vector<std::string> Resolve(const std::string& host,
                                   const std::string& adapter_luid,
                                   std::string* error) const;
  void Start(ChangeCallback callback);
  void Stop();

 private:
  static void WINAPI OnInterfaceChanged(PVOID context,
                                        PMIB_IPINTERFACE_ROW row,
                                        MIB_NOTIFICATION_TYPE type);
  ChangeCallback callback_;
  HANDLE notification_ = nullptr;
};

#endif
