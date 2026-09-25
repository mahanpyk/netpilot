#ifndef NETPILOT_NATIVE_SERVICE_SERVICE_RUNTIME_H_
#define NETPILOT_NATIVE_SERVICE_SERVICE_RUNTIME_H_

#include <atomic>
#include <mutex>
#include <string>
#include <vector>

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <netioapi.h>

#include "../common/netpilot_protocol.h"
#include "diagnostics.h"
#include "route_manager.h"
#include "relay_engine.h"
#include "wfp_policy.h"

class ServiceRuntime {
 public:
  ServiceRuntime();
  ~ServiceRuntime();

  bool Initialize(std::string* error);
  void Run(HANDLE stop_event);
  void Stop();

 private:
  bool ServeClient(HANDLE pipe);
  bool AuthorizeClient(HANDLE pipe, std::string* error) const;
  std::vector<uint8_t> Dispatch(netpilot::Operation operation,
                                const std::vector<uint8_t>& payload,
                                uint32_t client_session);
  netpilot::ServiceStatus Status(const std::string& message = {}) const;
  bool ValidateRules(const std::vector<netpilot::AppRuleSpec>& rules,
                     std::string* error) const;
  static void WINAPI OnInterfaceChanged(PVOID context,
                                        PMIB_IPINTERFACE_ROW row,
                                        MIB_NOTIFICATION_TYPE type);
  void ReapplyForNetworkChange();

  mutable std::mutex mutex_;
  Diagnostics diagnostics_;
  RouteManager routes_;
  WfpPolicy wfp_;
  RelayEngine relay_;
  bool master_enabled_ = false;
  bool proxy_running_ = false;
  std::string applied_hash_;
  std::vector<netpilot::AppRuleSpec> app_rules_;
  HANDLE interface_notification_ = nullptr;
  std::atomic<bool> stopping_{false};
};

#endif
