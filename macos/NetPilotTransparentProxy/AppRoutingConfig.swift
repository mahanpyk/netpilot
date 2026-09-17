import Foundation

enum AppFailurePolicy: String {
  case block
  case fallback
}

struct AppProxyRule {
  let id: String
  let displayName: String
  let signingIdentifiers: Set<String>
  let teamIdentifier: String
  let interfaceName: String
  let enabled: Bool
  let failurePolicy: AppFailurePolicy

  init?(dictionary: [String: Any]) {
    guard let id = dictionary["id"] as? String,
          let displayName = dictionary["displayName"] as? String,
          let signingIdentifier = dictionary["signingIdentifier"] as? String,
          let teamIdentifier = dictionary["teamIdentifier"] as? String,
          let interfaceName = dictionary["interfaceId"] as? String,
          !signingIdentifier.isEmpty,
          !teamIdentifier.isEmpty,
          !interfaceName.hasPrefix("utun") else { return nil }
    var identifiers = Set(dictionary["helperSigningIdentifiers"] as? [String] ?? [])
    identifiers.insert(signingIdentifier)
    self.id = id
    self.displayName = displayName
    self.signingIdentifiers = identifiers
    self.teamIdentifier = teamIdentifier
    self.interfaceName = interfaceName
    self.enabled = dictionary["enabled"] as? Bool ?? true
    self.failurePolicy = AppFailurePolicy(
      rawValue: dictionary["failurePolicy"] as? String ?? "block"
    ) ?? .block
  }
}

struct AppProxyConfiguration {
  let masterEnabled: Bool
  let rules: [AppProxyRule]
  let hash: String

  init(dictionary: [String: Any]) {
    masterEnabled = dictionary["masterEnabled"] as? Bool ?? false
    hash = dictionary["configurationHash"] as? String ?? ""
    rules = (dictionary["rules"] as? [[String: Any]] ?? [])
      .compactMap(AppProxyRule.init(dictionary:))
  }

  func match(signingIdentifier: String, teamIdentifier: String) -> AppProxyRule? {
    guard masterEnabled else { return nil }
    return rules.first {
      $0.enabled &&
        $0.teamIdentifier == teamIdentifier &&
        $0.signingIdentifiers.contains(signingIdentifier)
    }
  }
}

enum FlowRoutingDecision: Equatable {
  case direct
  case relay(ruleId: String, interfaceName: String)
  case block(ruleId: String, interfaceName: String)
}

struct FlowDecisionEngine {
  let configuration: AppProxyConfiguration

  func decision(
    signingIdentifier: String?,
    teamIdentifier: String?,
    availablePhysicalInterfaces: Set<String>
  ) -> FlowRoutingDecision {
    guard let signingIdentifier, let teamIdentifier,
          let rule = configuration.match(
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier
          ) else { return .direct }
    if availablePhysicalInterfaces.contains(rule.interfaceName) {
      return .relay(ruleId: rule.id, interfaceName: rule.interfaceName)
    }
    return rule.failurePolicy == .block
      ? .block(ruleId: rule.id, interfaceName: rule.interfaceName)
      : .direct
  }
}
