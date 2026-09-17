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
  func run(_ launchPath: String, arguments: [String]) throws -> String {
    calls.append((launchPath, arguments))
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
    XCTAssertEqual(runner.calls.count, 1)
    XCTAssertEqual(runner.calls[0].0, "/sbin/route")
    XCTAssertEqual(
      runner.calls[0].1,
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
      runner.calls[1].1,
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
      XCTAssertEqual(runner.calls.map { $0.1 }, [
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
      for (_, arguments) in runner.calls {
        let output = try ProcessCommandRunner().run(
          "/sbin/route", arguments: ["-n", "-d", "-v", "get"] + Array(arguments.dropFirst(2)))
        XCTAssertTrue(output.contains("lo0"), output)
        XCTAssertTrue(output.contains("2.189.86.112"), output)
        XCTAssertEqual(output.contains("flags:<UP,GATEWAY,STATIC>"), gateway != nil, output)
        XCTAssertFalse(output.contains("IFSCOPE"), output)
      }
    }
  }

}
