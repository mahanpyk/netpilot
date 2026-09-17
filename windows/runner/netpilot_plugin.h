#ifndef RUNNER_NETPILOT_PLUGIN_H_
#define RUNNER_NETPILOT_PLUGIN_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>

#include <memory>
#include <windows.h>

#include "service_client.h"
#include "windows_app_inspector.h"
#include "windows_network.h"

class NetPilotPlugin {
 public:
  NetPilotPlugin(flutter::BinaryMessenger* messenger, HWND window);
  ~NetPilotPlugin();
  void OnNetworkChanged();
  static constexpr UINT kNetworkChangedMessage = WM_APP + 0x4e50;

 private:
  using Value = flutter::EncodableValue;
  using Map = flutter::EncodableMap;
  using List = flutter::EncodableList;

  void HandleNetworkCall(
      const flutter::MethodCall<Value>& call,
      std::unique_ptr<flutter::MethodResult<Value>> result);
  void HandleAppRoutingCall(
      const flutter::MethodCall<Value>& call,
      std::unique_ptr<flutter::MethodResult<Value>> result);
  Map StatusMap(const netpilot::ServiceStatus& status) const;

  WindowsNetworkInventory inventory_;
  WindowsAppInspector app_inspector_;
  ServiceClient service_;
  std::unique_ptr<flutter::MethodChannel<Value>> network_channel_;
  std::unique_ptr<flutter::MethodChannel<Value>> app_channel_;
  std::unique_ptr<flutter::EventChannel<Value>> network_events_channel_;
  std::unique_ptr<flutter::EventChannel<Value>> app_events_channel_;
  std::unique_ptr<flutter::EventSink<Value>> network_sink_;
  std::unique_ptr<flutter::EventSink<Value>> app_sink_;
  HWND window_ = nullptr;
};

#endif
