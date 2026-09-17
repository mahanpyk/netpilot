import Foundation
import ServiceManagement

final class HelperXPCClient {
  func status() -> [String: Any] {
    if #available(macOS 13.0, *) {
      let service = SMAppService.daemon(plistName: NetPilotXPCConstants.launchdPlistName)
      switch service.status {
      case .enabled:
        return [
          "installed": true,
          "enabled": true,
          "status": "enabled",
        ]
      case .requiresApproval:
        return [
          "installed": true,
          "enabled": false,
          "status": "requiresApproval",
          "message": "Approve NetPilot Helper in System Settings → General → Login Items",
        ]
      case .notFound:
        return [
          "installed": false,
          "enabled": false,
          "status": "notFound",
          "message": "Helper not registered. Build with matching Team ID signatures.",
        ]
      case .notRegistered:
        return [
          "installed": false,
          "enabled": false,
          "status": "notRegistered",
        ]
      @unknown default:
        return [
          "installed": false,
          "enabled": false,
          "status": "unknown",
        ]
      }
    }
    return [
      "installed": false,
      "enabled": false,
      "status": "unsupportedOS",
      "message": "macOS 14+ required",
    ]
  }

  func install() -> [String: Any] {
    if #available(macOS 13.0, *) {
      let service = SMAppService.daemon(plistName: NetPilotXPCConstants.launchdPlistName)
      do {
        try service.register()
        var map = status()
        map["ok"] = (map["enabled"] as? Bool) ?? false
        return map
      } catch {
        var map = status()
        map["message"] = error.localizedDescription
        map["ok"] = false
        return map
      }
    }
    return status()
  }

  func reconcile(desired: [[String: Any]]) -> [String: Any] {
    let connection = NSXPCConnection(
      machServiceName: NetPilotXPCConstants.machServiceName,
      options: [.privileged]
    )
    connection.remoteObjectInterface = NSXPCInterface(with: NetPilotXPCProtocol.self)
    connection.resume()
    defer { connection.invalidate() }

    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
      NSLog("NetPilot XPC error: \(error.localizedDescription)")
    }) as? NetPilotXPCProtocol else {
      return [
        "ok": false,
        "added": 0,
        "removed": 0,
        "errors": ["Helper XPC proxy unavailable"],
      ]
    }

    let semaphore = DispatchSemaphore(value: 0)
    var result: [String: Any] = [
      "ok": false,
      "added": 0,
      "removed": 0,
      "errors": ["Timed out waiting for helper"],
    ]
    proxy.reconcileDesired(desired as NSArray) { reply in
      var map: [String: Any] = [:]
      reply.forEach { key, value in
        if let key = key as? String {
          map[key] = value
        }
      }
      result = map
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 8)
    return result
  }
}
