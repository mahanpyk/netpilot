import Cocoa
import FlutterMacOS
import ServiceManagement

protocol MainAppLoginService {
  var status: SMAppService.Status { get }
  func register() throws
  func unregister() throws
}

private struct SystemMainAppLoginService: MainAppLoginService {
  var status: SMAppService.Status { SMAppService.mainApp.status }
  func register() throws { try SMAppService.mainApp.register() }
  func unregister() throws { try SMAppService.mainApp.unregister() }
}

final class LaunchAtLoginManager {
  private let service: MainAppLoginService

  init(service: MainAppLoginService = SystemMainAppLoginService()) {
    self.service = service
  }

  func status() -> [String: Any] {
    let state = service.status
    var result: [String: Any] = ["enabled": state == .enabled]
    switch state {
    case .enabled:
      result["status"] = "enabled"
    case .notRegistered:
      result["status"] = "notRegistered"
    case .requiresApproval:
      result["status"] = "requiresApproval"
      result["message"] = "Approve NetPilot in System Settings > General > Login Items."
    case .notFound:
      result["status"] = "notFound"
      result["message"] = "Install NetPilot in Applications before enabling launch at login."
    @unknown default:
      result["status"] = "unknown"
      result["message"] = "macOS returned an unknown login item status."
    }
    return result
  }

  func setEnabled(_ enabled: Bool) -> [String: Any] {
    do {
      if enabled { try service.register() } else { try service.unregister() }
      return status()
    } catch {
      var result = status()
      result["message"] = "Could not \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
      NSLog("[NetPilot] Launch at login update failed: %@", error.localizedDescription)
      return result
    }
  }
}

final class NetPilotPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  static weak var current: NetPilotPlugin?
  private let inventory = NetworkInventoryService()
  private let helper = HelperXPCClient()
  private let launchAtLogin = LaunchAtLoginManager()
  private var eventSink: FlutterEventSink?
  private let worker = DispatchQueue(label: "com.netpilot.network-platform")

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NetPilotPlugin()
    current = instance
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
    case "getLaunchAtLoginStatus":
      result(launchAtLogin.status())
    case "setLaunchAtLogin":
      guard let args = call.arguments as? [String: Any], let enabled = args["enabled"] as? Bool else {
        result(FlutterError(code: "bad_arguments", message: "enabled must be a boolean", details: nil))
        return
      }
      result(launchAtLogin.setEnabled(enabled))
    case "setRoutingModeStatus":
      guard let args = call.arguments as? [String: Any],
            let mode = args["mode"] as? String,
            mode == "custom" || mode == "systemDefault" else {
        result(FlutterError(code: "bad_mode", message: "Unknown routing mode", details: nil))
        return
      }
      (NSApp.delegate as? AppDelegate)?.setRoutingMode(mode)
      result(nil)
    case "completeQuit":
      (NSApp.delegate as? AppDelegate)?.finishQuit()
      result(nil)
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

  @discardableResult
  func emitEvent(_ event: [String: Any]) -> Bool {
    guard let eventSink else { return false }
    eventSink(event)
    return true
  }
}
