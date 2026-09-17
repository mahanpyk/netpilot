#ifndef NETPILOT_NATIVE_SERVICE_ROUTE_MANAGER_H_
#define NETPILOT_NATIVE_SERVICE_ROUTE_MANAGER_H_

#include <string>
#include <vector>

#include "../common/netpilot_protocol.h"

class RouteManager {
 public:
  RouteManager();
  netpilot::ReconcileResult Reconcile(
      const std::vector<netpilot::RouteSpec>& desired);
  void Cleanup();

 private:
  bool Add(const netpilot::RouteSpec& route, std::string* error);
  bool Remove(const netpilot::RouteSpec& route, std::string* error);
  void Load();
  void Save() const;
  std::wstring state_path_;
  std::vector<netpilot::RouteSpec> managed_;
};

#endif
