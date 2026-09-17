#include <cassert>
#include <iostream>

#include "../common/netpilot_protocol.h"

int main() {
  const std::vector<netpilot::RouteSpec> routes = {
      {"203.0.113.10/32", "192.168.8.1", "123456", "netpilot:rule"}};
  netpilot::BufferWriter route_writer;
  netpilot::EncodeRoutes(routes, &route_writer);
  netpilot::BufferReader route_reader(route_writer.bytes());
  std::vector<netpilot::RouteSpec> decoded_routes;
  assert(netpilot::DecodeRoutes(&route_reader, &decoded_routes));
  assert(decoded_routes.size() == 1);
  assert(decoded_routes[0].interface_luid == "123456");
  std::string error;
  assert(netpilot::IsValidRoute(decoded_routes[0], &error));
  auto injection = decoded_routes[0];
  injection.interface_luid = "1 & powershell";
  assert(!netpilot::IsValidRoute(injection, &error));

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
  assert(netpilot::DecodeAppRules(&app_reader, &master, &hash, &decoded_apps));
  assert(master && hash == "hash" && decoded_apps.size() == 1);
  assert(netpilot::IsValidAppRule(decoded_apps[0], &error));
  decoded_apps[0].policy = "execute";
  assert(!netpilot::IsValidAppRule(decoded_apps[0], &error));

  std::cout << "NetPilot protocol tests passed\n";
  return 0;
}
