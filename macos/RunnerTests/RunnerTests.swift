import Cocoa
import FlutterMacOS
import XCTest
import dnssd

@testable import netpilot_desktop

class RunnerTests: XCTestCase {
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
