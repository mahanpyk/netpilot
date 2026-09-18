#include "netpilot_plugin.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <filesystem>
#include <iostream>
#include <shellapi.h>

namespace {

using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;

const Value* Find(const Map& map, const char* key) {
  const auto iterator = map.find(Value(key));
  return iterator == map.end() ? nullptr : &iterator->second;
}

std::string String(const Map& map, const char* key) {
  const auto* value = Find(map, key);
  const auto* string = value ? std::get_if<std::string>(value) : nullptr;
  return string ? *string : std::string();
}

bool Boolean(const Map& map, const char* key, bool fallback = false) {
  const auto* value = Find(map, key);
  const auto* boolean = value ? std::get_if<bool>(value) : nullptr;
  return boolean ? *boolean : fallback;
}

Value StringList(const std::vector<std::string>& values) {
  List list;
  for (const auto& value : values) list.emplace_back(value);
  return Value(list);
}

Map ErrorStatus(const std::string& message) {
  return {{Value("platform"), Value("windows")},
          {Value("extensionStatus"), Value("unavailable")},
          {Value("engineStatus"), Value("unavailable")},
          {Value("serviceStatus"), Value("unavailable")},
          {Value("driverStatus"), Value("unknown")},
          {Value("proxyStatus"), Value("stopped")},
          {Value("message"), Value(message)}};
}

bool LaunchMaintenanceRepair() {
  std::wstring module(32768, L'\0');
  const DWORD size = GetModuleFileNameW(
      nullptr, module.data(), static_cast<DWORD>(module.size()));
  if (!size) return false;
  module.resize(size);
  const auto maintenance =
      std::filesystem::path(module).parent_path() / L"NetPilotMaintenance.exe";
  const auto result = reinterpret_cast<INT_PTR>(ShellExecuteW(
      nullptr, L"runas", maintenance.c_str(), L"repair",
      maintenance.parent_path().c_str(), SW_SHOWNORMAL));
  return result > 32;
}

}  // namespace

NetPilotPlugin::NetPilotPlugin(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  const auto* codec = &flutter::StandardMethodCodec::GetInstance();
  network_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "com.netpilot.netpilotDesktop/network", codec);
  app_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "com.netpilot.netpilotDesktop/appRouting", codec);
  network_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleNetworkCall(call, std::move(result));
      });
  app_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleAppRoutingCall(call, std::move(result));
  });

  network_events_channel_ = std::make_unique<flutter::EventChannel<Value>>(
      messenger, "com.netpilot.netpilotDesktop/networkEvents", codec);
  network_events_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<Value>>(
          [this](const Value*,
                 std::unique_ptr<flutter::EventSink<Value>>&& sink) {
            network_sink_ = std::move(sink);
            inventory_.Start([this] {
              if (window_) PostMessageW(window_, kNetworkChangedMessage, 0, 0);
            });
            return nullptr;
          },
          [this](const Value*) {
            inventory_.Stop();
            network_sink_.reset();
            return nullptr;
          }));

  app_events_channel_ = std::make_unique<flutter::EventChannel<Value>>(
      messenger, "com.netpilot.netpilotDesktop/appRoutingEvents", codec);
  app_events_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<Value>>(
          [this](const Value*,
                 std::unique_ptr<flutter::EventSink<Value>>&& sink) {
            app_sink_ = std::move(sink);
            return nullptr;
          },
          [this](const Value*) {
            app_sink_.reset();
            return nullptr;
          }));
}

NetPilotPlugin::~NetPilotPlugin() { inventory_.Stop(); }

void NetPilotPlugin::OnNetworkChanged() {
  if (network_sink_)
    network_sink_->Success(
        Value(Map{{Value("type"), Value("interfacesChanged")}}));
}

void NetPilotPlugin::HandleNetworkCall(
    const flutter::MethodCall<Value>& call,
    std::unique_ptr<flutter::MethodResult<Value>> result) {
  if (call.method_name() == "listInterfaces") {
    std::string error;
    const auto adapters = inventory_.List(&error);
    if (!error.empty()) {
      std::cerr << "[NetPilot] " << error << std::endl;
      result->Error("network_inventory", error);
      return;
    }
    List output;
    for (const auto& adapter : adapters) {
      output.emplace_back(Map{
          {Value("id"), Value(adapter.id)},
          {Value("nativeId"), Value(adapter.native_id)},
          {Value("name"), Value(adapter.name)},
          {Value("interfaceName"), Value(adapter.interface_name)},
          {Value("kind"), Value(adapter.kind)},
          {Value("ipv4Addresses"), StringList(adapter.ipv4_addresses)},
          {Value("gateway"), Value(adapter.gateway)},
          {Value("dnsServers"), StringList(adapter.dns_servers)},
          {Value("isDefaultRoute"), Value(adapter.is_default_route)},
          {Value("isActive"), Value(adapter.is_active)},
      });
    }
    result->Success(Value(output));
    return;
  }
  if (call.method_name() == "resolveHost") {
    const auto* arguments = std::get_if<Map>(call.arguments());
    if (!arguments) {
      result->Error("bad_arguments", "resolveHost requires arguments");
      return;
    }
    std::string error;
    const auto addresses = inventory_.Resolve(
        String(*arguments, "host"), String(*arguments, "interfaceId"), &error);
    if (!error.empty()) {
      std::cerr << "[NetPilot] DNS: " << error << std::endl;
      result->Error("dns", error);
      return;
    }
    result->Success(Value(Map{{Value("ips"), StringList(addresses)}}));
    return;
  }
  if (call.method_name() == "getHelperStatus" ||
      call.method_name() == "installHelper") {
    if (call.method_name() == "installHelper" && !LaunchMaintenanceRepair()) {
      result->Success(Value(Map{
          {Value("installed"), Value(false)},
          {Value("enabled"), Value(false)},
          {Value("status"), Value("failed")},
          {Value("message"),
           Value("Could not launch NetPilot Maintenance with UAC")},
      }));
      return;
    }
    netpilot::ServiceStatus status;
    std::string error;
    const bool connected = service_.GetStatus(&status, &error);
    result->Success(Value(Map{
        {Value("installed"), Value(connected && status.service_ready)},
        {Value("enabled"), Value(connected && status.engine_ready)},
        {Value("status"),
         Value(connected && status.engine_ready ? "enabled" : "unavailable")},
        {Value("message"),
         Value(connected ? status.message
                         : error +
                               ". Run NetPilot Setup Repair with administrator access.")},
    }));
    return;
  }
  if (call.method_name() == "reconcileRoutes") {
    const auto* arguments = std::get_if<Map>(call.arguments());
    const auto* desired_value = arguments ? Find(*arguments, "desired") : nullptr;
    const auto* desired = desired_value ? std::get_if<List>(desired_value) : nullptr;
    if (!desired) {
      result->Error("bad_arguments", "reconcileRoutes requires desired routes");
      return;
    }
    std::vector<netpilot::RouteSpec> routes;
    for (const auto& item : *desired) {
      const auto* map = std::get_if<Map>(&item);
      if (!map) continue;
      routes.push_back({String(*map, "destination"), String(*map, "gateway"),
                        String(*map, "interfaceId"), String(*map, "tag")});
    }
    netpilot::ReconcileResult response;
    std::string error;
    if (!service_.ReconcileRoutes(routes, &response, &error)) {
      std::cerr << "[NetPilot] Route reconcile failed: " << error << std::endl;
      response.errors.push_back(error);
    }
    result->Success(Value(Map{
        {Value("ok"), Value(response.ok)},
        {Value("added"), Value(static_cast<int32_t>(response.added))},
        {Value("removed"), Value(static_cast<int32_t>(response.removed))},
        {Value("errors"), StringList(response.errors)},
    }));
    return;
  }
  if (call.method_name() == "windowAction") {
    result->Success();  // Windows uses its native title bar.
    return;
  }
  result->NotImplemented();
}

NetPilotPlugin::Map NetPilotPlugin::StatusMap(
    const netpilot::ServiceStatus& status) const {
  Map rule_metrics;
  for (const auto& metric : status.rule_metrics) {
    rule_metrics[Value(metric.id)] = Value(Map{
        {Value("activeFlows"), Value(static_cast<int64_t>(metric.active_flows))},
        {Value("bytesIn"), Value(static_cast<int64_t>(metric.bytes_in))},
        {Value("bytesOut"), Value(static_cast<int64_t>(metric.bytes_out))},
        {Value("lastError"), Value(metric.last_error)},
    });
  }
  return {{Value("platform"), Value("windows")},
          {Value("extensionStatus"),
           Value(status.engine_ready ? "installed" : "unavailable")},
          {Value("engineStatus"),
           Value(status.engine_ready ? "ready" : "unavailable")},
          {Value("serviceStatus"),
           Value(status.service_ready ? "running" : "stopped")},
          {Value("driverStatus"),
           Value(status.driver_ready ? "installed" : "missing")},
          {Value("proxyStatus"),
           Value(status.proxy_running ? "running" : "stopped")},
          {Value("rebootRequired"), Value(status.reboot_required)},
          {Value("testMode"), Value(status.test_mode)},
          {Value("appliedHash"), Value(status.applied_hash)},
          {Value("message"), Value(status.message)},
          {Value("activeFlows"), Value(static_cast<int64_t>(status.active_flows))},
          {Value("bytesIn"), Value(static_cast<int64_t>(status.bytes_in))},
          {Value("bytesOut"), Value(static_cast<int64_t>(status.bytes_out))},
          {Value("ruleMetrics"), Value(rule_metrics)}};
}

void NetPilotPlugin::HandleAppRoutingCall(
    const flutter::MethodCall<Value>& call,
    std::unique_ptr<flutter::MethodResult<Value>> result) {
  if (call.method_name() == "selectApplication") {
    std::string error;
    const auto application = app_inspector_.SelectAndInspect(&error);
    if (!application) {
      if (error.empty())
        result->Success();
      else
        result->Error("app_inspection", error);
      return;
    }
    List helpers;
    for (const auto& helper : application->helpers) {
      helpers.emplace_back(Map{{Value("path"), Value(helper.path)},
                               {Value("wfpAppId"), Value(helper.app_id)},
                               {Value("displayName"), Value(helper.display_name)},
                               {Value("publisher"), Value(helper.publisher)},
                               {Value("isSigned"), Value(helper.is_signed)},
                               {Value("enabled"), Value(helper.selected)}});
    }
    const auto& main = application->main;
    result->Success(Value(Map{
        {Value("platform"), Value("windows")},
        {Value("displayName"), Value(main.display_name)},
        {Value("bundlePath"), Value(main.path)},
        {Value("bundleIdentifier"), Value("")},
        {Value("signingIdentifier"), Value("")},
        {Value("teamIdentifier"), Value("")},
        {Value("executablePath"), Value(main.path)},
        {Value("wfpAppId"), Value(main.app_id)},
        {Value("publisher"), Value(main.publisher)},
        {Value("isSigned"), Value(main.is_signed)},
        {Value("iconPngBase64"), Value(application->icon_png_base64)},
        {Value("helperExecutables"), Value(helpers)},
    }));
    return;
  }
  if (call.method_name() == "getStatus" ||
      call.method_name() == "requestExtensionActivation") {
    if (call.method_name() == "requestExtensionActivation")
      LaunchMaintenanceRepair();
    netpilot::ServiceStatus status;
    std::string error;
    if (!service_.GetStatus(&status, &error)) {
      result->Success(Value(ErrorStatus(error)));
      return;
    }
    result->Success(Value(StatusMap(status)));
    return;
  }
  if (call.method_name() == "getDiagnostics") {
    std::vector<std::string> lines;
    std::string error;
    if (!service_.GetDiagnostics(&lines, &error) && !error.empty())
      lines.push_back("[NetPilot App Routing] " + error);
    result->Success(StringList(lines));
    return;
  }
  if (call.method_name() == "applyAndRestart") {
    const auto* arguments = std::get_if<Map>(call.arguments());
    const auto* rules_value = arguments ? Find(*arguments, "rules") : nullptr;
    const auto* rules = rules_value ? std::get_if<List>(rules_value) : nullptr;
    if (!arguments || !rules) {
      result->Error("bad_arguments", "applyAndRestart requires rules");
      return;
    }
    std::vector<netpilot::AppRuleSpec> specs;
    for (const auto& item : *rules) {
      const auto* map = std::get_if<Map>(&item);
      if (!map) continue;
      netpilot::AppRuleSpec spec;
      spec.id = String(*map, "id");
      spec.interface_luid = String(*map, "interfaceId");
      spec.policy = String(*map, "failurePolicy");
      spec.enabled = Boolean(*map, "enabled", true);
      spec.executables.push_back(
          {String(*map, "executablePath"), String(*map, "wfpAppId")});
      const auto* helpers_value = Find(*map, "helperExecutables");
      const auto* helpers = helpers_value ? std::get_if<List>(helpers_value) : nullptr;
      if (helpers) {
        for (const auto& helper_value : *helpers) {
          const auto* helper = std::get_if<Map>(&helper_value);
          if (helper)
            spec.executables.push_back(
                {String(*helper, "path"), String(*helper, "wfpAppId")});
        }
      }
      specs.push_back(std::move(spec));
    }
    if (app_sink_)
      app_sink_->Success(Value(Map{{Value("type"), Value("reconnecting")}}));
    netpilot::ServiceStatus status;
    std::string error;
    if (!service_.ApplyAppRouting(Boolean(*arguments, "masterEnabled"),
                                  String(*arguments, "configurationHash"),
                                  specs, &status, &error)) {
      result->Success(Value(ErrorStatus(error)));
      return;
    }
    result->Success(Value(StatusMap(status)));
    return;
  }
  result->NotImplemented();
}
