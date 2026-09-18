#include <cstdlib>
#include <iostream>

#include "../common/netpilot_protocol.h"

namespace {

void Check(bool condition, const char* message) {
  if (condition) return;
  std::cerr << "NetPilot protocol test failed: " << message << '\n';
  std::exit(EXIT_FAILURE);
}

}  // namespace

int main() {
  const std::vector<netpilot::RouteSpec> routes = {
      {"203.0.113.10/32", "192.168.8.1", "123456", "netpilot:rule"}};
  netpilot::BufferWriter route_writer;
  netpilot::EncodeRoutes(routes, &route_writer);
  netpilot::BufferReader route_reader(route_writer.bytes());
  std::vector<netpilot::RouteSpec> decoded_routes;
  Check(netpilot::DecodeRoutes(&route_reader, &decoded_routes),
        "route payload should decode");
  Check(decoded_routes.size() == 1, "one route should decode");
  Check(decoded_routes[0].interface_luid == "123456",
        "route LUID should round trip");
  std::string error;
  Check(netpilot::IsValidRoute(decoded_routes[0], &error),
        "valid route should pass validation");
  auto injection = decoded_routes[0];
  injection.interface_luid = "1 & powershell";
  Check(!netpilot::IsValidRoute(injection, &error),
        "injected LUID should fail validation");

  netpilot::AppRuleSpec app;
  app.id = "browser-rule";
  app.interface_luid = "123456";
  app.policy = "block";
  app.executables.push_back(
      {R"(C:\Program Files\Browser\browser.exe)", "aabbcc"});
  netpilot::BufferWriter app_writer;
  netpilot::EncodeAppRules(true, "hash", {app}, &app_writer);
  netpilot::BufferReader app_reader(app_writer.bytes());
  bool master = false;
  std::string hash;
  std::vector<netpilot::AppRuleSpec> decoded_apps;
  Check(netpilot::DecodeAppRules(&app_reader, &master, &hash, &decoded_apps),
        "app-rule payload should decode");
  Check(master && hash == "hash" && decoded_apps.size() == 1,
        "app-rule state should round trip");
  Check(netpilot::IsValidAppRule(decoded_apps[0], &error),
        "valid app rule should pass validation");
  decoded_apps[0].policy = "execute";
  Check(!netpilot::IsValidAppRule(decoded_apps[0], &error),
        "invalid policy should fail validation");

  std::cout << "NetPilot protocol tests passed\n";
  return 0;
}
