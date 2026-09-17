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
    // Fixed argv only — never interpolate free-form shell strings.
    var args = ["-n", "add", "-net", spec.destination]
    if let gateway = spec.gateway, !gateway.isEmpty {
      args.append(gateway)
    }
    args.append(contentsOf: ["-iface", spec.interfaceName])
    _ = try runner.run("/sbin/route", arguments: args)
  }

  private func deleteRoute(_ spec: RouteSpec) throws {
    var args = ["-n", "delete", "-net", spec.destination]
    if let gateway = spec.gateway, !gateway.isEmpty {
      args.append(gateway)
    }
    _ = try runner.run("/sbin/route", arguments: args)
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
