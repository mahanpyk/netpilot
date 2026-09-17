import AppKit
import FlutterMacOS
import UniformTypeIdentifiers

final class AppRoutingPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let inspector = AppInspector()
  private let manager = AppRoutingManager()
  private var eventSink: FlutterEventSink?
  private var statusTimer: Timer?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = AppRoutingPlugin()
    let methods = FlutterMethodChannel(
      name: "com.netpilot.netpilotDesktop/appRouting",
      binaryMessenger: registrar.messenger
    )
    let events = FlutterEventChannel(
      name: "com.netpilot.netpilotDesktop/appRoutingEvents",
      binaryMessenger: registrar.messenger
    )
    registrar.addMethodCallDelegate(instance, channel: methods)
    events.setStreamHandler(instance)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "selectApplication":
      selectApplication(result: result)
    case "getStatus":
      manager.status(completion: result)
    case "requestExtensionActivation":
      manager.requestActivation { [weak self] status in
        result(status)
        self?.eventSink?(["type": "extensionStatusChanged"])
      }
    case "applyAndRestart":
      let arguments = call.arguments as? [String: Any]
      let masterEnabled = arguments?["masterEnabled"] as? Bool ?? false
      let rules = arguments?["rules"] as? [[String: Any]] ?? []
      let configurationHash = arguments?["configurationHash"] as? String ?? ""
      eventSink?(["type": "reconnecting"])
      manager.applyAndRestart(
        masterEnabled: masterEnabled,
        rules: rules,
        configurationHash: configurationHash
      ) { [weak self] response in
        switch response {
        case .success(let status): result(status)
        case .failure(let error):
          result(FlutterError(
            code: "app_routing_apply_failed",
            message: error.localizedDescription,
            details: nil
          ))
        }
        self?.eventSink?(["type": "proxyStatusChanged"])
      }
    case "getDiagnostics":
      result(manager.currentDiagnostics())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func selectApplication(result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.title = "Choose an application"
    panel.prompt = "Add Application"
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.applicationBundle]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url else {
        result(nil)
        return
      }
      do {
        let descriptor = try self?.inspector.inspect(url: url)
        NSLog(
          "[NetPilot App Routing] inspected app=%@ signing=%@ team=%@",
          descriptor?["bundlePath"] as? String ?? "",
          descriptor?["signingIdentifier"] as? String ?? "",
          descriptor?["teamIdentifier"] as? String ?? ""
        )
        result(descriptor)
      } catch {
        NSLog("[NetPilot App Routing] integration gate failed: %@", error.localizedDescription)
        result(FlutterError(
          code: "app_identity_unavailable",
          message: "Integration gate failed: \(error.localizedDescription)",
          details: nil
        ))
      }
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    statusTimer?.invalidate()
    statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      self?.manager.status { status in
        var event = status
        event.removeValue(forKey: "diagnostics")
        event["type"] = "metricsUpdated"
        self?.eventSink?(event)
      }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    statusTimer?.invalidate()
    statusTimer = nil
    return nil
  }
}
