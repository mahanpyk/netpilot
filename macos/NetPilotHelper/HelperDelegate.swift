import Foundation
import Security

final class HelperDelegate: NSObject, NSXPCListenerDelegate, NetPilotXPCProtocol {
  private let routeManager = RouteManager()
  private let clientRequirement: String? = {
    var ownCode: SecCode?
    guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode else {
      return nil
    }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess,
          let staticCode else {
      return nil
    }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(
      staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
    ) == errSecSuccess,
          let values = information as? [String: Any],
          let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
          team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
      return nil
    }
    return "identifier \"com.netpilot.netpilotDesktop\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
  }()

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    guard let clientRequirement else {
      NSLog("[NetPilot] Rejecting XPC client: helper has no valid Team ID")
      return false
    }
    newConnection.setCodeSigningRequirement(clientRequirement)
    newConnection.exportedInterface = NSXPCInterface(with: NetPilotXPCProtocol.self)
    newConnection.exportedObject = self
    newConnection.resume()
    return true
  }

  func ping(withReply reply: @escaping (Bool) -> Void) {
    reply(true)
  }

  func listManagedRoutes(withReply reply: @escaping (NSArray) -> Void) {
    reply(routeManager.managedDictionaries() as NSArray)
  }

  func reconcileDesired(
    _ desired: NSArray,
    withReply reply: @escaping (NSDictionary) -> Void
  ) {
    var specs: [RouteSpec] = []
    var errors: [String] = []
    for item in desired {
      guard let dict = item as? [String: Any],
            let spec = RouteSpec(dictionary: dict)
      else {
        errors.append("invalid route payload")
        continue
      }
      if let err = RouteSpec.validate(spec) {
        errors.append(err)
        continue
      }
      specs.append(spec)
    }

    let result = routeManager.reconcile(desired: specs)
    reply([
      "ok": result.errors.isEmpty && errors.isEmpty,
      "added": result.added,
      "removed": result.removed,
      "errors": errors + result.errors,
    ] as NSDictionary)
  }
}
