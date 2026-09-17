import Foundation

struct ReconcileResult {
  var added: Int = 0
  var removed: Int = 0
  var errors: [String] = []
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
        result.errors.append("delete \(spec.destination): \(error.localizedDescription)")
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

    persist()
    return result
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
