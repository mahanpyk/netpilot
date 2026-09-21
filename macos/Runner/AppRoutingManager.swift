import Foundation
import NetworkExtension
import SystemExtensions

final class AppRoutingManager: NSObject, OSSystemExtensionRequestDelegate {
  static let extensionIdentifier = "com.netpilot.netpilotDesktop.TransparentProxy"

  private var activationCompletion: (([String: Any]) -> Void)?
  private var approvalRequired = false
  private var lastMessage: String?
  private var diagnostics: [String] = []
  private var activationSucceeded = false
  private var forwardedProviderLines = Set<String>()

  func status(completion: @escaping ([String: Any]) -> Void) {
    if let signingError = signingError() {
      var payload = baseStatus()
      payload["extensionStatus"] = "signingRequired"
      payload["proxyStatus"] = "unconfigured"
      payload["message"] = signingError
      completion(payload)
      return
    }
    NETransparentProxyManager.loadAllFromPreferences { [weak self] managers, error in
      guard let self else { return }
      let manager = managers?.first(where: {
        ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.extensionIdentifier
      })
      var payload = self.baseStatus()
      if let error {
        payload["message"] = error.localizedDescription
      }
      payload["proxyStatus"] = self.statusName(manager?.connection.status ?? .invalid)
      payload["extensionStatus"] = (manager == nil && !self.activationSucceeded)
        ? "notInstalled" : "installed"
      payload["appliedHash"] = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?
        .providerConfiguration?["configurationHash"] as? String
      self.readProviderDiagnostics(manager: manager) { providerStatus in
        payload.merge(providerStatus) { _, new in new }
        completion(payload)
      }
    }
  }

  func requestActivation(completion: @escaping ([String: Any]) -> Void) {
    if let signingError = signingError() {
      log("System Extension activation unavailable: \(signingError)")
      status(completion: completion)
      return
    }
    approvalRequired = false
    lastMessage = nil
    activationCompletion = completion
    log("requesting System Extension activation")
    let request = OSSystemExtensionRequest.activationRequest(
      forExtensionWithIdentifier: Self.extensionIdentifier,
      queue: .main
    )
    request.delegate = self
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  func applyAndRestart(
    masterEnabled: Bool,
    rules: [[String: Any]],
    configurationHash: String,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    if let signingError = signingError() {
      completion(.failure(NSError(
        domain: "NetPilotAppRouting",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: signingError]
      )))
      return
    }
    NETransparentProxyManager.loadAllFromPreferences { [weak self] managers, loadError in
      guard let self else { return }
      if let loadError {
        completion(.failure(loadError))
        return
      }
      let manager = managers?.first(where: {
        ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.extensionIdentifier
      }) ?? NETransparentProxyManager()
      let provider = (manager.protocolConfiguration as? NETunnelProviderProtocol)
        ?? NETunnelProviderProtocol()
      provider.providerBundleIdentifier = Self.extensionIdentifier
      provider.serverAddress = "NetPilot Transparent Proxy"
      provider.providerConfiguration = [
        "version": 1,
        "masterEnabled": masterEnabled,
        "rules": rules,
        "configurationHash": configurationHash,
      ]
      manager.protocolConfiguration = provider
      manager.localizedDescription = "NetPilot Per-App Routing"
      manager.isEnabled = masterEnabled

      self.log("saving configuration hash=\(configurationHash) rules=\(rules.count)")
      manager.saveToPreferences { saveError in
        if let saveError {
          completion(.failure(saveError))
          return
        }
        manager.loadFromPreferences { reloadError in
          if let reloadError {
            completion(.failure(reloadError))
            return
          }
          manager.connection.stopVPNTunnel()
          guard masterEnabled else {
            self.log("proxy stopped")
            self.status { completion(.success($0)) }
            return
          }
          self.startAfterStop(manager: manager, attempt: 0, completion: completion)
        }
      }
    }
  }

  func currentDiagnostics() -> [String] {
    diagnostics
  }

  func request(
    _ request: OSSystemExtensionRequest,
    actionForReplacingExtension existing: OSSystemExtensionProperties,
    withExtension ext: OSSystemExtensionProperties
  ) -> OSSystemExtensionRequest.ReplacementAction {
    .replace
  }

  func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
    approvalRequired = true
    lastMessage = "Approve NetPilot in System Settings › General › Login Items & Extensions › Network Extensions."
    log("System Extension requires user approval")
    // Do not leave Flutter waiting while System Settings owns the approval flow.
    finishActivation()
  }

  func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
    activationSucceeded = result == .completed
    if result == .willCompleteAfterReboot {
      lastMessage = "Restart macOS to finish installing the NetPilot System Extension."
    }
    log("System Extension activation finished result=\(result.rawValue)")
    finishActivation()
  }

  func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
    lastMessage = error.localizedDescription
    log("System Extension activation failed: \(error.localizedDescription)")
    finishActivation()
  }

  private func finishActivation() {
    let completion = activationCompletion
    activationCompletion = nil
    status { completion?($0) }
  }

  private func baseStatus() -> [String: Any] {
    [
      "extensionStatus": lastMessage == nil || approvalRequired ? "installed" : "error",
      "approvalRequired": approvalRequired,
      "message": lastMessage as Any,
      "activeFlows": 0,
      "bytesIn": 0,
      "bytesOut": 0,
    ]
  }

  private func signingError() -> String? {
    let inspector = AppInspector()
    let extensionURL = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Library/SystemExtensions/NetPilotTransparentProxy.systemextension"
    )
    guard let appIdentity = try? inspector.codeIdentity(at: Bundle.main.bundleURL),
          let extensionIdentity = try? inspector.codeIdentity(at: extensionURL),
          appIdentity.teamIdentifier == extensionIdentity.teamIdentifier else {
      return "This build cannot activate App Routing. Sign NetPilot and its Transparent Proxy with the same Apple Developer Team and approved Network Extension profiles."
    }
    return nil
  }

  private func statusName(_ status: NEVPNStatus) -> String {
    switch status {
    case .connected: return "running"
    case .connecting, .reasserting: return "reconnecting"
    case .disconnecting: return "stopping"
    case .disconnected: return "stopped"
    case .invalid: return "unconfigured"
    @unknown default: return "unknown"
    }
  }

  private func readProviderDiagnostics(
    manager: NETransparentProxyManager?,
    completion: @escaping ([String: Any]) -> Void
  ) {
    guard manager?.connection.status == .connected,
          let session = manager?.connection as? NETunnelProviderSession,
          let message = "status".data(using: .utf8) else {
      completion([:])
      return
    }
    do {
      try session.sendProviderMessage(message) { response in
        guard let response,
              let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
          completion([:])
          return
        }
        self.forwardProviderDiagnostics(object["diagnostics"] as? [String] ?? [])
        completion(object)
      }
    } catch {
      log("provider diagnostics failed: \(error.localizedDescription)")
      completion([:])
    }
  }

  private func startAfterStop(
    manager: NETransparentProxyManager,
    attempt: Int,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    let status = manager.connection.status
    guard status == .disconnected || status == .invalid || attempt >= 25 else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        self.startAfterStop(manager: manager, attempt: attempt + 1, completion: completion)
      }
      return
    }
    do {
      try manager.connection.startVPNTunnel()
      log("proxy restart requested after stop status=\(statusName(status))")
      waitForReady(manager: manager, attempt: 0, completion: completion)
    } catch {
      completion(.failure(error))
    }
  }

  private func waitForReady(
    manager: NETransparentProxyManager,
    attempt: Int,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    if manager.connection.status == .connected || attempt >= 50 {
      status { completion(.success($0)) }
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      self.waitForReady(manager: manager, attempt: attempt + 1, completion: completion)
    }
  }

  private func log(_ message: String) {
    let line = "[NetPilot App Routing] \(message)"
    NSLog("%@", line)
    diagnostics.append(line)
    if diagnostics.count > 200 { diagnostics.removeFirst(diagnostics.count - 200) }
  }

  private func forwardProviderDiagnostics(_ lines: [String]) {
    if forwardedProviderLines.count > 1_000 {
      forwardedProviderLines.removeAll(keepingCapacity: true)
    }
    for line in lines where forwardedProviderLines.insert(line).inserted {
      NSLog("%@", line)
      diagnostics.append(line)
    }
    if diagnostics.count > 200 {
      diagnostics.removeFirst(diagnostics.count - 200)
    }
  }
}
