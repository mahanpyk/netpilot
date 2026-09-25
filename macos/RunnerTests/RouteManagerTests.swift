import Foundation
import XCTest

@testable import netpilot_desktop

final class RouteSpecTests: XCTestCase {
  func testValidCidrAndInterface() {
    let spec = RouteSpec(
      destination: "10.0.0.1/32",
      gateway: "10.0.0.1",
      interfaceName: "en7",
      tag: "netpilot:abc"
    )
    XCTAssertNil(RouteSpec.validate(spec))
  }

  func testRejectsBadTag() {
    let spec = RouteSpec(
      destination: "10.0.0.1/32",
      gateway: nil,
      interfaceName: "en7",
      tag: "other"
    )
    XCTAssertNotNil(RouteSpec.validate(spec))
  }

  func testRejectsShellInjectionInInterface() {
    let spec = RouteSpec(
      destination: "10.0.0.1/32",
      gateway: nil,
      interfaceName: "en0;rm",
      tag: "netpilot:x"
    )
    XCTAssertNotNil(RouteSpec.validate(spec))
  }
}

final class MockRunner: CommandRunning {
  var calls: [(String, [String])] = []
  var throwWhenDeletingMissingRoute = false
  var socketListing = ""
  var processCommands: [Int32: String] = [:]
  private var routes: [String: (gateway: String?, interfaceName: String)] = [:]

  var mutationCalls: [(String, [String])] {
    calls.filter {
      $0.0 == "/sbin/route" && $0.1.count > 1 && $0.1[1] != "get"
    }
  }

  func run(_ launchPath: String, arguments: [String]) throws -> String {
    calls.append((launchPath, arguments))
    if launchPath == "/usr/sbin/lsof" { return socketListing }
    if launchPath == "/bin/ps", arguments.count > 1,
       let pid = Int32(arguments[1]) {
      return processCommands[pid] ?? ""
    }
    guard arguments.count > 2 else { return "" }
    switch arguments[1] {
    case "add":
      let destination = arguments[3]
      if let interfaceIndex = arguments.firstIndex(of: "-ifp") {
        routes[destination] = (
          arguments[4],
          String(arguments[interfaceIndex + 1].dropLast())
        )
      } else if let interfaceIndex = arguments.firstIndex(of: "-interface") {
        routes[destination] = (nil, arguments[interfaceIndex + 1])
      }
    case "delete":
      let removed = routes.removeValue(forKey: arguments[3])
      if removed == nil && throwWhenDeletingMissingRoute {
        throw NSError(
          domain: "MockRoute", code: 3,
          userInfo: [NSLocalizedDescriptionKey: "route: writing to routing socket: not in table"]
        )
      }
    case "get":
      let target = arguments[2]
      let match = routes.first {
        $0.key == "\(target)/32" ||
          $0.key.split(separator: "/").first == Substring(target)
      }?.value
      return """
         route to: \(target)
      destination: \(match == nil ? "default" : target)
          gateway: \(match?.gateway ?? "192.0.2.254")
        interface: \(match?.interfaceName ?? "en0")
      """
    default:
      break
    }
    return ""
  }
}

final class RouteManagerTests: XCTestCase {
  func testReconcileAddsAndRemovesWithFixedArgv() throws {
    let runner = MockRunner()
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = dir.appendingPathComponent("managed.json")
    let manager = RouteManager(runner: runner, storeURL: store)

    let a = RouteSpec(
      destination: "10.1.1.1/32",
      gateway: "10.0.0.1",
      interfaceName: "en7",
      tag: "netpilot:1"
    )
    let first = manager.reconcile(desired: [a])
    XCTAssertEqual(first.added, 1)
    XCTAssertEqual(first.routeChecks.map(\.verified), [true])
    XCTAssertEqual(runner.mutationCalls.count, 1)
    XCTAssertEqual(runner.mutationCalls[0].0, "/sbin/route")
    XCTAssertEqual(
      runner.mutationCalls[0].1,
      ["-n", "add", "-net", "10.1.1.1/32", "10.0.0.1", "-ifp", "en7:"]
    )

    let b = RouteSpec(
      destination: "10.1.1.2/32",
      gateway: "10.0.0.1",
      interfaceName: "en7",
      tag: "netpilot:1"
    )
    let second = manager.reconcile(desired: [b])
    XCTAssertEqual(second.added, 1)
    XCTAssertEqual(second.removed, 1)
    XCTAssertEqual(
      runner.mutationCalls[1].1,
      ["-n", "delete", "-net", "10.1.1.1/32", "10.0.0.1", "-ifp", "en7:"]
    )
  }

  func testDirectRoutesUseInterfaceWithoutGatewayForAddAndDelete() throws {
    for gateway: String? in [nil, ""] {
      let runner = MockRunner()
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: dir) }
      let manager = RouteManager(runner: runner, storeURL: dir.appendingPathComponent("managed.json"))
      let spec = RouteSpec(destination: "10.20.0.0/16", gateway: gateway,
                           interfaceName: "en8", tag: "netpilot:direct")
      XCTAssertEqual(manager.reconcile(desired: [spec]).added, 1)
      XCTAssertEqual(manager.reconcile(desired: []).removed, 1)
      XCTAssertEqual(runner.mutationCalls.map { $0.1 }, [
        ["-n", "add", "-net", "10.20.0.0/16", "-interface", "en8"],
        ["-n", "delete", "-net", "10.20.0.0/16", "-interface", "en8"],
      ])
    }
  }

  func testMacOSParsesGatewayAndDirectRouteArguments() throws {
    // GET uses the same argument parser as ADD/DELETE and needs no privilege.
    // -d prevents even a routing-socket request: this never changes routes.
    for gateway: String? in ["192.0.2.1", nil] {
      let runner = MockRunner()
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: dir) }
      let manager = RouteManager(runner: runner, storeURL: dir.appendingPathComponent("managed.json"))
      let spec = RouteSpec(destination: "2.189.86.112/32", gateway: gateway,
                           interfaceName: "lo0", tag: "netpilot:parser")
      XCTAssertEqual(manager.reconcile(desired: [spec]).added, 1)
      XCTAssertEqual(manager.reconcile(desired: []).removed, 1)
      for (_, arguments) in runner.mutationCalls {
        let output = try ProcessCommandRunner().run(
          "/sbin/route", arguments: ["-n", "-d", "-v", "get"] + Array(arguments.dropFirst(2)))
        XCTAssertTrue(output.contains("lo0"), output)
        XCTAssertTrue(output.contains("2.189.86.112"), output)
        XCTAssertEqual(output.contains("flags:<UP,GATEWAY,STATIC>"), gateway != nil, output)
        XCTAssertFalse(output.contains("IFSCOPE"), output)
      }
    }
  }

  func testReconcileRepairsPersistedRouteMissingFromKernel() throws {
    let runner = MockRunner()
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = dir.appendingPathComponent("managed.json")
    let spec = RouteSpec(
      destination: "203.0.113.9/32", gateway: "10.0.0.1",
      interfaceName: "en8", tag: "netpilot:persisted"
    )
    let data = try JSONSerialization.data(withJSONObject: [spec.dictionary])
    try data.write(to: store)

    let result = RouteManager(runner: runner, storeURL: store)
      .reconcile(desired: [spec])

    XCTAssertEqual(result.added, 1)
    XCTAssertTrue(result.errors.isEmpty)
    XCTAssertEqual(result.routeChecks.map(\.verified), [true])
    XCTAssertEqual(runner.mutationCalls.map { $0.1 }, [[
      "-n", "add", "-net", "203.0.113.9/32", "10.0.0.1", "-ifp", "en8:",
    ]])
  }

  func testRemovingPersistedRouteAlreadyMissingFromKernelSucceeds() throws {
    let runner = MockRunner()
    runner.throwWhenDeletingMissingRoute = true
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = dir.appendingPathComponent("managed.json")
    let spec = RouteSpec(
      destination: "203.0.113.10/32", gateway: "10.0.0.1",
      interfaceName: "en8", tag: "netpilot:stale"
    )
    let data = try JSONSerialization.data(withJSONObject: [spec.dictionary])
    try data.write(to: store)

    let result = RouteManager(runner: runner, storeURL: store)
      .reconcile(desired: [])

    XCTAssertEqual(result.removed, 1)
    XCTAssertTrue(result.errors.isEmpty)
    XCTAssertTrue(RouteManager(runner: runner, storeURL: store).managedDictionaries().isEmpty)
  }

  func testChangedRouteRestartsOnlySafeBrowserNetworkServices() throws {
    let runner = MockRunner()
    runner.socketListing = [
      "p424\0cGoogle Chrome Helper\0f12\0n192.168.1.2:50100->203.0.113.44:443\0",
      "p425\0cOtherApp\0f13\0n192.168.1.2:50101->203.0.113.44:443\0",
    ].joined(separator: "\n")
    runner.processCommands = [
      424: "/Applications/Google Chrome Helper --type=utility --utility-sub-type=network.mojom.NetworkService",
      425: "/Applications/OtherApp.app/Contents/MacOS/OtherApp",
    ]
    var signals: [(pid_t, Int32)] = []
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let manager = RouteManager(
      runner: runner,
      storeURL: dir.appendingPathComponent("managed.json"),
      signalProcess: { pid, signal in
        signals.append((pid, signal))
        return 0
      }
    )
    let spec = RouteSpec(
      destination: "203.0.113.0/24", gateway: "10.0.0.1",
      interfaceName: "en8", tag: "netpilot:browser"
    )

    let result = manager.reconcile(desired: [spec])

    XCTAssertEqual(signals.count, 1)
    XCTAssertEqual(signals.first?.0, 424)
    XCTAssertEqual(signals.first?.1, SIGTERM)
    XCTAssertEqual(result.restartedProcesses.map(\.pid), [424])
  }

}
