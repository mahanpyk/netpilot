import Cocoa
import FlutterMacOS

final class NetPilotPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let inventory = NetworkInventoryService()
  private let helper = HelperXPCClient()
  private var eventSink: FlutterEventSink?
  private let worker = DispatchQueue(label: "com.netpilot.network-platform")

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
      worker.async {
        let interfaces = self.inventory.listInterfaces()
        DispatchQueue.main.async { result(interfaces) }
      }
    case "resolveHost":
      let args = call.arguments as? [String: Any]
      let host = (args?["host"] as? String) ?? ""
      let interfaceId = args?["interfaceId"] as? String
      inventory.resolveHost(host, interfaceId: interfaceId, completion: result)
    case "getHelperStatus":
      worker.async {
        let status = self.helper.status()
        DispatchQueue.main.async { result(status) }
      }
    case "installHelper":
      worker.async {
        let status = self.helper.install()
        DispatchQueue.main.async { result(status) }
      }
    case "reconcileRoutes":
      let args = call.arguments as? [String: Any]
      let desired = (args?["desired"] as? [[String: Any]]) ?? []
      worker.async {
        let applied = self.helper.reconcile(desired: desired)
        DispatchQueue.main.async { result(applied) }
      }
    case "reconcileHostMappings":
      let args = call.arguments as? [String: Any]
      let desired = (args?["desired"] as? [[String: Any]]) ?? []
      worker.async {
        let applied = self.helper.reconcileHostMappings(desired: desired)
        DispatchQueue.main.async { result(applied) }
      }
    case "windowAction":
      let args = call.arguments as? [String: Any]
      switch args?["action"] as? String {
      case "close":
        NSApp.keyWindow?.performClose(nil)
      case "minimize":
        NSApp.keyWindow?.miniaturize(nil)
      case "zoom":
        NSApp.keyWindow?.zoom(nil)
      default:
        result(FlutterError(code: "bad_action", message: "Unknown window action", details: nil))
        return
      }
      result(nil)
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
