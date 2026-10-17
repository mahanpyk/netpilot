import Foundation
import ServiceManagement

final class HelperXPCClient {
  func status() -> [String: Any] {
    if #available(macOS 13.0, *) {
      let service = SMAppService.daemon(plistName: NetPilotXPCConstants.launchdPlistName)
      switch service.status {
      case .enabled:
        let health = ping()
        if !health.ok {
          return [
            "installed": true,
            "enabled": false,
            "status": "unreachable",
            "message": (health.message ?? "Helper is registered but not responding.")
              + " Use Repair. If it remains unavailable, sign the app and helper with the same Apple Development team.",
          ]
        }
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
        if service.status == .enabled {
          try service.unregister()
        }
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
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var completed = false
    var result: [String: Any] = [
      "ok": false,
      "added": 0,
      "removed": 0,
      "errors": ["Timed out waiting for helper"],
    ]
    func finish(_ value: [String: Any]) {
      lock.lock()
      defer { lock.unlock() }
      guard !completed else { return }
      completed = true
      result = value
      semaphore.signal()
    }

    let connection = NSXPCConnection(
      machServiceName: NetPilotXPCConstants.machServiceName,
      options: [.privileged]
    )
    connection.remoteObjectInterface = NSXPCInterface(with: NetPilotXPCProtocol.self)
    connection.resume()
    defer { connection.invalidate() }

    connection.interruptionHandler = {
      finish([
        "ok": false, "added": 0, "removed": 0,
        "errors": ["Helper connection interrupted"],
      ])
    }
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
      let message = "Helper XPC error: \(error.localizedDescription)"
      NSLog("NetPilot \(message)")
      finish(["ok": false, "added": 0, "removed": 0, "errors": [message]])
    }) as? NetPilotXPCProtocol else {
      return [
        "ok": false,
        "added": 0,
        "removed": 0,
        "errors": ["Helper XPC proxy unavailable"],
      ]
    }

    proxy.reconcileDesired(desired as NSArray) { reply in
      var map: [String: Any] = [:]
      reply.forEach { key, value in
        if let key = key as? String {
          map[key] = value
        }
      }
      finish(map)
    }
    _ = semaphore.wait(timeout: .now() + 8)
    return result
  }

  func reconcileHostMappings(desired: [[String: Any]]) -> [String: Any] {
    // Legacy rule sets need no new helper method unless a managed block needs
    // cleanup. Do not send an unknown selector to an older installed helper.
    if desired.isEmpty,
       let hosts = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8),
       !hosts.contains("NETPILOT MANAGED HOSTS") {
      return ["ok": true, "changed": false, "errors": [String]()]
    }
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var completed = false
    var result: [String: Any] = [:]
    func finish(_ value: [String: Any]) {
      lock.lock()
      defer { lock.unlock() }
      guard !completed else { return }
      completed = true
      result = value
      semaphore.signal()
    }
    func errorResult(_ message: String) -> [String: Any] {
      ["ok": false, "changed": false, "errors": [
        message + " Repair NetPilot Helper in Settings to enable hostname mappings.",
      ]]
    }
    let connection = NSXPCConnection(
      machServiceName: NetPilotXPCConstants.machServiceName, options: [.privileged]
    )
    connection.remoteObjectInterface = NSXPCInterface(with: NetPilotXPCProtocol.self)
    connection.interruptionHandler = { finish(errorResult("Helper connection interrupted.")) }
    connection.invalidationHandler = { finish(errorResult("Helper connection unavailable or out of date.")) }
    connection.resume()
    defer { connection.invalidate() }
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
      finish(errorResult("Helper XPC error: \(error.localizedDescription)."))
    }) as? NetPilotXPCProtocol else { return errorResult("Helper XPC proxy unavailable.") }
    proxy.reconcileHostMappingsDesired(desired as NSArray, deadline: Date().timeIntervalSince1970 + 5) { reply in
      var map: [String: Any] = [:]
      reply.forEach { key, value in if let key = key as? String { map[key] = value } }
      finish(map)
    }
    if semaphore.wait(timeout: .now() + 8) == .timedOut {
      finish(errorResult("Timed out waiting for helper; mapping state could not be confirmed."))
    }
    lock.lock()
    defer { lock.unlock() }
    return result
  }

  private func ping() -> (ok: Bool, message: String?) {
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var completed = false
    var response = (ok: false, message: Optional("Timed out pinging helper"))
    func finish(_ value: (ok: Bool, message: String?)) {
      lock.lock()
      defer { lock.unlock() }
      guard !completed else { return }
      completed = true
      response = value
      semaphore.signal()
    }

    let connection = NSXPCConnection(
      machServiceName: NetPilotXPCConstants.machServiceName,
      options: [.privileged]
    )
    connection.remoteObjectInterface = NSXPCInterface(with: NetPilotXPCProtocol.self)
    connection.resume()
    defer { connection.invalidate() }

    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
      finish((false, "Helper XPC error: \(error.localizedDescription)"))
    }) as? NetPilotXPCProtocol else {
      return (false, "Helper XPC proxy unavailable")
    }
    proxy.ping { ok in finish((ok, ok ? nil : "Helper ping failed")) }
    _ = semaphore.wait(timeout: .now() + 2)
    return response
  }
}
