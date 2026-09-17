import Foundation
import Network
import NetworkExtension

final class TransparentProxyProvider: NETransparentProxyProvider {
  private let queue = DispatchQueue(label: "com.netpilot.transparent-proxy")
  private let identityResolver = AppIdentityResolver()
  private let interfaceResolver = InterfaceResolver()
  private var configuration = AppProxyConfiguration(dictionary: [:])
  private var relays: [ObjectIdentifier: AnyObject] = [:]
  private var bytesIn = 0
  private var bytesOut = 0
  private var ruleMetrics: [String: RuleMetrics] = [:]
  private var diagnosticLines: [String] = []

  private struct RuleMetrics {
    var activeFlows = 0
    var bytesIn = 0
    var bytesOut = 0
    var lastError: String?
  }

  override func startProxy(
    options: [String: Any]? = nil,
    completionHandler: @escaping (Error?) -> Void
  ) {
    let dictionary =
      (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
    configuration = AppProxyConfiguration(dictionary: dictionary)
    let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    settings.includedNetworkRules = [
      NENetworkRule(
        destinationNetwork: NWHostEndpoint(hostname: "0.0.0.0", port: "0"),
        prefix: 0,
        protocol: .TCP
      ),
      NENetworkRule(
        destinationNetwork: NWHostEndpoint(hostname: "0.0.0.0", port: "0"),
        prefix: 0,
        protocol: .UDP
      ),
    ]
    setTunnelNetworkSettings(settings) { error in
      self.log("started hash=\(self.configuration.hash) rules=\(self.configuration.rules.count) error=\(error?.localizedDescription ?? "none")")
      completionHandler(error)
    }
  }

  override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    queue.async {
      self.relays.removeAll()
      self.log("stopped reason=\(reason.rawValue)")
      completionHandler()
    }
  }

  override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
    guard let identity = identityResolver.identity(for: flow.metaData) else {
      log("identity metadata unavailable; flow left to macOS")
      return false
    }
    guard let rule = configuration.match(
      signingIdentifier: identity.signingIdentifier,
      teamIdentifier: identity.teamIdentifier
    ) else { return false }
    let interface = interfaceResolver.physicalInterface(named: rule.interfaceName)
    let decision = FlowDecisionEngine(configuration: configuration).decision(
      signingIdentifier: identity.signingIdentifier,
      teamIdentifier: identity.teamIdentifier,
      availablePhysicalInterfaces: interface == nil ? [] : [rule.interfaceName]
    )
    switch decision {
    case .direct:
      if interface == nil {
        updateError(rule.id, "Interface \(rule.interfaceName) unavailable; using normal macOS route")
        log("fallback app=\(identity.signingIdentifier) interface=\(rule.interfaceName)")
      }
      return false
    case .block:
      let error = NSError(
        domain: NEAppProxyErrorDomain,
        code: NEAppProxyFlowError.notConnected.rawValue,
        userInfo: [NSLocalizedDescriptionKey: "Required physical interface is unavailable"]
      )
      flow.closeReadWithError(error)
      flow.closeWriteWithError(error)
      updateError(rule.id, error.localizedDescription)
      log("blocked app=\(identity.signingIdentifier) interface=\(rule.interfaceName)")
      return true
    case .relay:
      break
    }
    guard let interface else { return false }
    let id = ObjectIdentifier(flow)
    updateMetrics(rule.id) { $0.activeFlows += 1; $0.lastError = nil }
    let onBytes: (Int, Int) -> Void = { [weak self] sent, received in
      self?.queue.async {
        self?.bytesOut += sent
        self?.bytesIn += received
        self?.updateMetrics(rule.id) {
          $0.bytesOut += sent
          $0.bytesIn += received
        }
      }
    }
    let onClose: () -> Void = { [weak self] in
      self?.queue.async {
        self?.relays.removeValue(forKey: id)
        self?.updateMetrics(rule.id) { $0.activeFlows = max(0, $0.activeFlows - 1) }
      }
    }

    if let tcpFlow = flow as? NEAppProxyTCPFlow,
       let endpoint = tcpFlow.remoteEndpoint as? NWHostEndpoint {
      let parameters = NWParameters.tcp
      parameters.requiredInterface = interface
      let connection = NWConnection(
        host: NWEndpoint.Host(endpoint.hostname),
        port: NWEndpoint.Port(endpoint.port) ?? .any,
        using: parameters
      )
      let relay = TCPFlowRelay(
        flow: tcpFlow,
        connection: connection,
        queue: queue,
        onBytes: onBytes,
        onClose: onClose
      )
      relays[id] = relay
      log("TCP app=\(identity.signingIdentifier) interface=\(rule.interfaceName) destination=\(endpoint.hostname):\(endpoint.port)")
      relay.start()
      return true
    }
    if let udpFlow = flow as? NEAppProxyUDPFlow {
      let relay = UDPFlowRelay(
        flow: udpFlow,
        interface: interface,
        queue: queue,
        onBytes: onBytes,
        onClose: onClose
      )
      relays[id] = relay
      log("UDP/QUIC app=\(identity.signingIdentifier) interface=\(rule.interfaceName)")
      relay.start()
      return true
    }
    return false
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
    let payload: [String: Any] = [
      "activeFlows": relays.count,
      "bytesIn": bytesIn,
      "bytesOut": bytesOut,
      "configurationHash": configuration.hash,
      "ruleMetrics": ruleMetrics.mapValues { metrics in
        var value: [String: Any] = [
          "activeFlows": metrics.activeFlows,
          "bytesIn": metrics.bytesIn,
          "bytesOut": metrics.bytesOut,
        ]
        if let lastError = metrics.lastError { value["lastError"] = lastError }
        return value
      },
      "diagnostics": diagnosticLines,
    ]
    completionHandler?(try? JSONSerialization.data(withJSONObject: payload))
  }

  private func log(_ message: String) {
    let line = "[NetPilot App Routing] \(message)"
    NSLog("%@", line)
    diagnosticLines.append(line)
    if diagnosticLines.count > 200 {
      diagnosticLines.removeFirst(diagnosticLines.count - 200)
    }
  }

  private func updateError(_ ruleId: String, _ message: String) {
    updateMetrics(ruleId) { $0.lastError = message }
  }

  private func updateMetrics(_ ruleId: String, _ update: (inout RuleMetrics) -> Void) {
    var metrics = ruleMetrics[ruleId] ?? RuleMetrics()
    update(&metrics)
    ruleMetrics[ruleId] = metrics
  }
}
