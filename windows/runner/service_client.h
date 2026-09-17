#ifndef RUNNER_SERVICE_CLIENT_H_
#define RUNNER_SERVICE_CLIENT_H_

#include <string>
#include <vector>

#include "../native/common/netpilot_protocol.h"

class ServiceClient {
 public:
  bool GetStatus(netpilot::ServiceStatus* status, std::string* error) const;
  bool ReconcileRoutes(const std::vector<netpilot::RouteSpec>& routes,
                       netpilot::ReconcileResult* result,
                       std::string* error) const;
  bool ApplyAppRouting(bool master_enabled, const std::string& hash,
                       const std::vector<netpilot::AppRuleSpec>& rules,
                       netpilot::ServiceStatus* status,
                       std::string* error) const;
  bool GetDiagnostics(std::vector<std::string>* lines,
                      std::string* error) const;

 private:
  bool Call(netpilot::Operation operation, const std::vector<uint8_t>& request,
            std::vector<uint8_t>* response, std::string* error) const;
};

#endif
