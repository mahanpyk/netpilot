import Cocoa
import FlutterMacOS

final class NetPilotPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let inventory = NetworkInventoryService()
  private let helper = HelperXPCClient()
  private var eventSink: FlutterEventSink?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NetPilotPlugin()
    let method = FlutterMethodChannel(
      name: "com.netpilot.netpilotDesktop/network",
      binaryMessenger: registrar.messenger
    )
    let events = FlutterEventChannel(
      name: "com.netpilot.netpilotDesktop/networkEvents",
      binaryMessenger: registrar.messenger
    )
    registrar.addMethodCallDelegate(instance, channel: method)
    events.setStreamHandler(instance)
    instance.inventory.startMonitoring {
      DispatchQueue.main.async {
        instance.eventSink?(["type": "interfacesChanged"])
      }
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "listInterfaces":
      result(inventory.listInterfaces())
    case "resolveHost":
      let args = call.arguments as? [String: Any]
      let host = (args?["host"] as? String) ?? ""
      let interfaceId = args?["interfaceId"] as? String
      result(inventory.resolveHost(host, interfaceId: interfaceId))
    case "getHelperStatus":
      result(helper.status())
    case "installHelper":
      result(helper.install())
    case "reconcileRoutes":
      let args = call.arguments as? [String: Any]
      let desired = (args?["desired"] as? [[String: Any]]) ?? []
      result(helper.reconcile(desired: desired))
    case "applyRoutes", "removeRoutes":
      // Unified through reconcile for MVP.
      result([
        "ok": false,
        "added": 0,
        "removed": 0,
        "errors": ["Use reconcileRoutes"],
      ])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
