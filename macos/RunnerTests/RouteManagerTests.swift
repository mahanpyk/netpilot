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
      ["-n", "add", "-net", "10.1.1.1/32", "10.0.0.1", "-iface", "en7"]
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
    XCTAssertTrue(runner.calls.contains(where: { $0.1.contains("delete") }))
  }
}
