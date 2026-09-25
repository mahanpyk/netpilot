import Foundation

struct ReconcileResult {
  var added: Int = 0
  var removed: Int = 0
  var errors: [String] = []
  var routeChecks: [RouteCheck] = []
}

struct RouteCheck {
  let destination: String
  let expectedInterface: String
  let expectedGateway: String?
  let actualInterface: String?
  let actualGateway: String?
  let verified: Bool
  let message: String?

  var dictionary: [String: Any] {
    var value: [String: Any] = [
      "destination": destination,
      "expectedInterface": expectedInterface,
      "verified": verified,
    ]
    if let expectedGateway { value["expectedGateway"] = expectedGateway }
    if let actualInterface { value["actualInterface"] = actualInterface }
    if let actualGateway { value["actualGateway"] = actualGateway }
    if let message { value["message"] = message }
    return value
  }
}

protocol CommandRunning {
  @discardableResult
  func run(_ launchPath: String, arguments: [String]) throws -> String
}

struct ProcessCommandRunner: CommandRunning {
  func run(_ launchPath: String, arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let pipe = Pipe()
    let err = Pipe()
    process.standardOutput = pipe
    process.standardError = err
    try process.run()
    process.waitUntilExit()
    let outData = pipe.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    if process.terminationStatus != 0 {
      let message = String(data: errData, encoding: .utf8) ?? "command failed"
      throw NSError(
        domain: "NetPilotHelper",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }
    return String(data: outData, encoding: .utf8) ?? ""
  }
}

final class RouteManager {
  private let runner: CommandRunning
  private let storeURL: URL
  private var managed: [RouteSpec]

  init(
    runner: CommandRunning = ProcessCommandRunner(),
    storeURL: URL = RouteManager.defaultStoreURL()
  ) {
    self.runner = runner
    self.storeURL = storeURL
    self.managed = RouteManager.load(from: storeURL)
  }

  static func defaultStoreURL() -> URL {
    let base = URL(fileURLWithPath: "/Library/Application Support/NetPilot")
    return base.appendingPathComponent("managed_routes.json")
  }

  func managedDictionaries() -> [[String: Any]] {
    managed.map(\.dictionary)
  }

  func reconcile(desired: [RouteSpec]) -> ReconcileResult {
    var result = ReconcileResult()
    let desiredSet = Set(desired.map(RouteKey.init))
    let currentSet = Set(managed.map(RouteKey.init))

    let toAdd = desired.filter { !currentSet.contains(RouteKey($0)) }
    let toRemove = managed.filter { !desiredSet.contains(RouteKey($0)) }

    for spec in toRemove {
      do {
        try deleteRoute(spec)
        managed.removeAll { $0 == spec }
        result.removed += 1
      } catch {
        if isMissingRouteError(error) {
          // The kernel table is volatile. A route that disappeared after a
          // reboot is already removed; discard only its stale inventory row.
          managed.removeAll { $0 == spec }
          result.removed += 1
        } else {
          result.errors.append("delete \(spec.destination): \(error.localizedDescription)")
        }
      }
    }

    for spec in toAdd {
      do {
        try addRoute(spec)
        managed.append(spec)
        result.added += 1
      } catch {
        result.errors.append("add \(spec.destination): \(error.localizedDescription)")
      }
    }

    // The JSON inventory survives reboot while the kernel routing table does
    // not. Never trust the inventory alone: verify every desired route and
    // re-add entries that were only present in the persisted inventory.
    for spec in desired {
      var check = inspectRoute(spec)
      if !check.verified && currentSet.contains(RouteKey(spec)) && !toAdd.contains(spec) {
        do {
          try addRoute(spec)
          result.added += 1
          check = inspectRoute(spec)
        } catch {
          let repairError = "repair \(spec.destination): \(error.localizedDescription)"
          result.errors.append(repairError)
          check = RouteCheck(
            destination: spec.destination,
            expectedInterface: spec.interfaceName,
            expectedGateway: spec.gateway,
            actualInterface: check.actualInterface,
            actualGateway: check.actualGateway,
            verified: false,
            message: repairError
          )
        }
      }
      if !check.verified, let message = check.message,
         !result.errors.contains(message) {
        result.errors.append(message)
      }
      result.routeChecks.append(check)
    }

    persist()
    return result
  }

  private func inspectRoute(_ spec: RouteSpec) -> RouteCheck {
    let target = String(spec.destination.split(separator: "/", maxSplits: 1)[0])
    do {
      let output = try runner.run("/sbin/route", arguments: ["-n", "get", target])
      let fields = output.split(separator: "\n").reduce(into: [String: String]()) { values, line in
        let parts = line.split(separator: ":", maxSplits: 1).map {
          $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.count == 2 { values[parts[0]] = parts[1] }
      }
      let actualInterface = fields["interface"]
      let actualGateway = fields["gateway"]
      let interfaceMatches = actualInterface == spec.interfaceName
      let gatewayMatches = spec.gateway.map { $0 == actualGateway } ?? true
      let verified = interfaceMatches && gatewayMatches
      let message = verified ? nil :
        "route \(spec.destination) expected \(spec.interfaceName)" +
        (spec.gateway.map { " via \($0)" } ?? "") +
        ", actual \(actualInterface ?? "unavailable")" +
        (actualGateway.map { " via \($0)" } ?? "")
      return RouteCheck(
        destination: spec.destination,
        expectedInterface: spec.interfaceName,
        expectedGateway: spec.gateway,
        actualInterface: actualInterface,
        actualGateway: actualGateway,
        verified: verified,
        message: message
      )
    } catch {
      return RouteCheck(
        destination: spec.destination,
        expectedInterface: spec.interfaceName,
        expectedGateway: spec.gateway,
        actualInterface: nil,
        actualGateway: nil,
        verified: false,
        message: "route check \(spec.destination): \(error.localizedDescription)"
      )
    }
  }

  private func isMissingRouteError(_ error: Error) -> Bool {
    let message = error.localizedDescription.lowercased()
    return message.contains("not in table") || message.contains("no such process")
  }

  private func addRoute(_ spec: RouteSpec) throws {
    _ = try runner.run("/sbin/route", arguments: routeArguments("add", spec))
  }

  private func deleteRoute(_ spec: RouteSpec) throws {
    _ = try runner.run("/sbin/route", arguments: routeArguments("delete", spec))
  }

  private func routeArguments(_ operation: String, _ spec: RouteSpec) -> [String] {
    // Fixed argv only — never interpolate free-form shell strings.
    var args = ["-n", operation, "-net", spec.destination]
    if let gateway = spec.gateway, !gateway.isEmpty {
      // -interface is a direct-route flag, not an interface selector. After
      // a gateway it makes the interface name parse as a second IP address.
      // -ifp selects the outgoing interface while preserving RTF_GATEWAY.
      // The trailing colon makes link_addr parse a BSD interface name.
      args.append(contentsOf: [gateway, "-ifp", "\(spec.interfaceName):"])
    } else {
      args.append(contentsOf: ["-interface", spec.interfaceName])
    }
    return args
  }

  private func persist() {
    let dir = storeURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let payload = managed.map(\.dictionary)
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
      try? data.write(to: storeURL, options: .atomic)
    }
  }

  private static func load(from url: URL) -> [RouteSpec] {
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
      return []
    }
    return json.compactMap(RouteSpec.init(dictionary:))
  }
}

private struct RouteKey: Hashable {
  let destination: String
  let gateway: String?
  let interfaceName: String
  let tag: String

  init(_ spec: RouteSpec) {
    destination = spec.destination
    gateway = spec.gateway
    interfaceName = spec.interfaceName
    tag = spec.tag
  }
}
