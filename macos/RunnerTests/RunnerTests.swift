import Cocoa
import FlutterMacOS
import XCTest
import dnssd
import ServiceManagement

@testable import netpilot_desktop

class RunnerTests: XCTestCase {
  func testRunningApplicationUsesNetPilotAppDelegate() {
    XCTAssertTrue(NSApp.delegate is AppDelegate, "The main nib must install AppDelegate")
    XCTAssertNotNil((NSApp.delegate as? AppDelegate)?.statusItem,
                    "The launched app must install its menu bar item")
  }

  func testMenuBarStatusItemUsesNetPilotIconAndStableIdentity() throws {
    let appDelegate = AppDelegate()
    appDelegate.installStatusItem()
    defer { appDelegate.removeStatusItem() }

    let item = try XCTUnwrap(appDelegate.statusItem)
    XCTAssertEqual(item.autosaveName, "com.netpilot.netpilotDesktop.statusItem")
    XCTAssertTrue(item.isVisible)
    XCTAssertNotNil(item.button?.image)
    XCTAssertEqual(item.button?.image?.size, NSSize(width: 18, height: 18))
  }

  func testClosingLastWindowKeepsAppRunning() {
    XCTAssertFalse(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApp))
  }

  func testLaunchAtLoginRegistrationAndRemoval() {
    let service = FakeMainAppLoginService()
    let manager = LaunchAtLoginManager(service: service)

    XCTAssertEqual(manager.status()["enabled"] as? Bool, false)
    XCTAssertEqual(manager.setEnabled(true)["enabled"] as? Bool, true)
    XCTAssertEqual(service.registerCount, 1)
    XCTAssertEqual(manager.setEnabled(false)["enabled"] as? Bool, false)
    XCTAssertEqual(service.unregisterCount, 1)
  }

  func testLaunchAtLoginApprovalAndRegistrationErrorAreVisible() {
    let service = FakeMainAppLoginService()
    service.status = .requiresApproval
    let manager = LaunchAtLoginManager(service: service)
    XCTAssertEqual(manager.status()["enabled"] as? Bool, false)
    XCTAssertEqual(manager.status()["status"] as? String, "requiresApproval")
    XCTAssertNotNil(manager.status()["message"] as? String)

    service.status = .notRegistered
    service.registerError = NSError(domain: "test", code: 1)
    let failed = manager.setEnabled(true)
    XCTAssertEqual(failed["enabled"] as? Bool, false)
    XCTAssertNotNil(failed["message"] as? String)
  }

  func testHelperRepairWaitsForUnregisterCompletion() throws {
    var stopped = false
    try HelperXPCClient.waitForUnregister({ completion in
      DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(30)) {
        stopped = true
        completion(nil)
      }
    }, timeout: .seconds(1))
    XCTAssertTrue(stopped)

    XCTAssertThrowsError(try HelperXPCClient.waitForUnregister({ completion in
      completion(NSError(domain: "test", code: 7))
    }, timeout: .seconds(1)))
  }

  func testHelperRepairRetriesTransientRegistrationFailure() throws {
    var attempts = 0
    try HelperXPCClient.registerWithOneRetry({
      attempts += 1
      if attempts == 1 { throw NSError(domain: "test", code: 1) }
    }, shouldRetry: { true }, delay: {})
    XCTAssertEqual(attempts, 2)

    attempts = 0
    XCTAssertThrowsError(try HelperXPCClient.registerWithOneRetry({
      attempts += 1
      throw NSError(domain: "test", code: 2)
    }, shouldRetry: { false }, delay: {}))
    XCTAssertEqual(attempts, 1)
  }

  func testRouteSpecValidation() {
    let ok = RouteSpec(
      destination: "10.0.0.1/32",
      gateway: "10.0.0.1",
      interfaceName: "en7",
      tag: "netpilot:abc"
    )
    XCTAssertNil(RouteSpec.validate(ok))
  }

  func testHostsIPv4AliasesCommentsAndCase() {
    let hosts = """
    # ignored 192.168.1.1 private.test
    ::1 private.test
    192.168.2.122 alias.test PRIVATE.TEST # company host
    192.168.2.122 private.test
    999.2.3.4 private.test
    172.20.109.17 private.test another.test
    """
    XCTAssertEqual(
      IPv4HostResolver.hostsAddresses(host: "Private.Test.", contents: hosts),
      ["192.168.2.122", "172.20.109.17"]
    )
    XCTAssertEqual(IPv4HostResolver.hostsAddresses(host: "absent.test", contents: hosts), [])
  }

  func testHostsMappingTakesPrecedenceWithoutStartingDNS() {
    let resolved = expectation(description: "hosts callback on main thread")
    let resolver = IPv4HostResolver(
      hostsContents: { "192.168.2.122 private.test" },
      makeQuery: { _ in XCTFail("Hosts entry must bypass DNS"); return SilentIPv4DNSQuery() }
    )
    resolver.resolve("private.test", interfaceId: nil) { ips in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual(ips, ["192.168.2.122"])
      resolved.fulfill()
    }
    wait(for: [resolved], timeout: 1)
  }

  func testUnresponsiveDNSTimesOutAndLeavesMainThreadResponsive() {
    let query = SilentIPv4DNSQuery()
    let resolved = expectation(description: "unresponsive DNS has a hard deadline")
    let heartbeat = expectation(description: "main thread remains responsive")
    let resolver = IPv4HostResolver(
      timeout: 0.05,
      hostsContents: { "" },
      makeQuery: { _ in query }
    )
    resolver.resolve("unresponsive.test", interfaceId: "lo0") { ips in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual(ips, [])
      XCTAssertEqual(query.interfaceIndex, if_nametoindex("lo0"))
      XCTAssertEqual(query.cancelCount, 1)
      resolved.fulfill()
    }
    DispatchQueue.main.async { heartbeat.fulfill() }
    wait(for: [heartbeat, resolved], timeout: 1)
  }

  func testInvalidInterfaceDoesNotFallBackToDefaultDNS() {
    let resolved = expectation(description: "invalid interface fails promptly")
    let resolver = IPv4HostResolver(
      hostsContents: { "" },
      makeQuery: { _ in XCTFail("Must not silently query the default interface"); return SilentIPv4DNSQuery() }
    )
    resolver.resolve("private.test", interfaceId: "nonexistent-netpilot") { ips in
      XCTAssertEqual(ips, [])
      resolved.fulfill()
    }
    wait(for: [resolved], timeout: 1)
  }

}


private final class SilentIPv4DNSQuery: IPv4DNSQuery {
  var interfaceIndex: UInt32?
  var cancelCount = 0

  func start(
    host: String,
    interfaceIndex: UInt32,
    reply: @escaping (DNSServiceFlags, DNSServiceErrorType, String?) -> Void
  ) -> DNSServiceErrorType {
    self.interfaceIndex = interfaceIndex
    return DNSServiceErrorType(kDNSServiceErr_NoError)
  }

  func cancel() { cancelCount += 1 }
}

private final class FakeMainAppLoginService: MainAppLoginService {
  var status: SMAppService.Status = .notRegistered
  var registerError: Error?
  var registerCount = 0
  var unregisterCount = 0

  func register() throws {
    registerCount += 1
    if let registerError { throw registerError }
    status = .enabled
  }

  func unregister() throws {
    unregisterCount += 1
    status = .notRegistered
  }
}
