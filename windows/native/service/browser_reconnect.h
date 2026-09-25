#ifndef NETPILOT_NATIVE_SERVICE_BROWSER_RECONNECT_H_
#define NETPILOT_NATIVE_SERVICE_BROWSER_RECONNECT_H_

#include <cstdint>
#include <string>
#include <vector>

#include "../common/netpilot_protocol.h"

// Best-effort Chromium network-service restart. Windows exposes TCP peers but
// only local UDP endpoints, so QUIC requires a session-scoped process restart.
class BrowserReconnect {
 public:
  static std::vector<netpilot::ReconcileResult::RestartedProcess> Reconnect(
      const std::vector<std::string>& changed_destinations,
      uint32_t client_session, std::string* warning);
};

#endif
