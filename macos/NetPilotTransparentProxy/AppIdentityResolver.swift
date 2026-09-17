import Foundation
import NetworkExtension
import Security

struct FlowAppIdentity {
  let signingIdentifier: String
  let teamIdentifier: String
}

final class AppIdentityResolver {
  func identity(for metadata: NEFlowMetaData) -> FlowAppIdentity? {
    let signingIdentifier = metadata.sourceAppSigningIdentifier
    guard !signingIdentifier.isEmpty,
          let auditToken = metadata.sourceAppAuditToken else { return nil }
    let attributes = [
      kSecGuestAttributeAudit as String: auditToken as CFData,
    ] as CFDictionary
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
          let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
          let staticCode else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(
      staticCode,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &information
    ) == errSecSuccess,
      let dictionary = information as? [String: Any],
      let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
      !teamIdentifier.isEmpty else { return nil }
    return FlowAppIdentity(
      signingIdentifier: signingIdentifier,
      teamIdentifier: teamIdentifier
    )
  }
}
