import Foundation

final class HelperDelegate: NSObject, NSXPCListenerDelegate, NetPilotXPCProtocol {
  private let routeManager = RouteManager()

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
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
