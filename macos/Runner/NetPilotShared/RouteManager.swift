import Darwin
import Foundation

struct ReconcileResult {
  var added: Int = 0
  var removed: Int = 0
  var errors: [String] = []
  var routeChecks: [RouteCheck] = []
  var connectionResetDestinations: [String] = []
  var restartedProcesses: [RestartedNetworkProcess] = []
}

struct RestartedNetworkProcess {
  let pid: Int32
  let name: String

  var dictionary: [String: Any] { ["pid": Int(pid), "name": name] }
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
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    // Drain stdout while the process is running. `lsof` can emit enough socket
    // rows to fill a pipe; waiting first would then deadlock the helper.
    let outData = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      let message = String(data: outData, encoding: .utf8) ?? "command failed"
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
  private let signalProcess: (pid_t, Int32) -> Int32
  private var managed: [RouteSpec]

  init(
    runner: CommandRunning = ProcessCommandRunner(),
    storeURL: URL = RouteManager.defaultStoreURL(),
    signalProcess: @escaping (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) }
  ) {
    self.runner = runner
    self.storeURL = storeURL
    self.signalProcess = signalProcess
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
    var removedDestinations = Set<String>()
    var addedDestinations = Set<String>()
    let desiredSet = Set(desired.map(RouteKey.init))
    let currentSet = Set(managed.map(RouteKey.init))

    let toAdd = desired.filter { !currentSet.contains(RouteKey($0)) }
    let toRemove = managed.filter { !desiredSet.contains(RouteKey($0)) }

    for spec in toRemove {
      do {
        try deleteRoute(spec)
        managed.removeAll { $0 == spec }
        result.removed += 1
        removedDestinations.insert(spec.destination)
      } catch {
        if isMissingRouteError(error) {
          // The kernel table is volatile. A route that disappeared after a
          // reboot is already removed; discard only its stale inventory row.
          managed.removeAll { $0 == spec }
          result.removed += 1
          removedDestinations.insert(spec.destination)
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
        addedDestinations.insert(spec.destination)
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
          addedDestinations.insert(spec.destination)
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

    let verifiedDestinations = Set(
      result.routeChecks.filter(\.verified).map(\.destination)
    )
    let destinationsToReset = removedDestinations.union(
      addedDestinations.intersection(verifiedDestinations)
    )
    if !destinationsToReset.isEmpty {
      result.connectionResetDestinations = destinationsToReset.sorted()
      result.restartedProcesses = restartBrowserNetworkProcesses(
        connectingTo: destinationsToReset
      )
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

  private func restartBrowserNetworkProcesses(
    connectingTo destinations: Set<String>
  ) -> [RestartedNetworkProcess] {
    let cidrs = destinations.compactMap(IPv4CIDR.init)
    guard !cidrs.isEmpty else { return [] }

    let listing: String
    do {
      listing = try runner.run(
        "/usr/sbin/lsof",
        arguments: ["-nP", "-a", "-iTCP", "-iUDP", "-F0pcn"]
      )
    } catch {
      return []
    }

    var currentPID: Int32?
    var processNames: [Int32: String] = [:]
    var candidates = Set<Int32>()
    for rawField in listing.split(separator: "\0", omittingEmptySubsequences: true) {
      let field = rawField.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let type = field.first else { continue }
      let value = String(field.dropFirst())
      switch type {
      case "p":
        currentPID = Int32(value)
      case "c":
        if let currentPID { processNames[currentPID] = value }
      case "n":
        guard let currentPID,
              let arrow = value.range(of: "->"),
              let remoteIP = Self.remoteIPv4(
                from: String(value[arrow.upperBound...])
              ),
              cidrs.contains(where: { $0.contains(remoteIP) })
        else { continue }
        candidates.insert(currentPID)
      default:
        continue
      }
    }

    var restarted: [RestartedNetworkProcess] = []
    for pid in candidates.sorted() where pid > 1 {
      guard let command = try? runner.run(
        "/bin/ps", arguments: ["-p", String(pid), "-o", "command="]
      ) else { continue }
      let isChromiumNetworkService = command.contains(
        "--utility-sub-type=network.mojom.NetworkService"
      )
      let isWebKitNetworkService = command.contains(
        "/com.apple.WebKit.Networking"
      )
      guard isChromiumNetworkService || isWebKitNetworkService else { continue }
      if signalProcess(pid_t(pid), SIGTERM) == 0 {
        restarted.append(
          RestartedNetworkProcess(
            pid: pid,
            name: processNames[pid] ??
              (isWebKitNetworkService ? "WebKit Networking" : "Chromium Network Service")
          )
        )
      }
    }
    return restarted
  }

  private static func remoteIPv4(from endpoint: String) -> String? {
    guard !endpoint.hasPrefix("["),
          let colon = endpoint.lastIndex(of: ":")
    else { return nil }
    let host = String(endpoint[..<colon])
    return RouteSpec.isValidIPv4(host) ? host : nil
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

private struct IPv4CIDR {
  let network: UInt32
  let mask: UInt32

  init?(_ value: String) {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2,
          let address = Self.address(String(parts[0])),
          let prefix = UInt32(parts[1]), prefix <= 32
    else { return nil }
    mask = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
    network = address & mask
  }

  func contains(_ value: String) -> Bool {
    guard let address = Self.address(value) else { return false }
    return address & mask == network
  }

  private static func address(_ value: String) -> UInt32? {
    let octets = value.split(separator: ".").compactMap { UInt32(String($0)) }
    guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else {
      return nil
    }
    return octets.reduce(0) { ($0 << 8) | $1 }
  }
}
