import Darwin
import Foundation
import XCTest

@testable import netpilot_desktop

final class ManagedHostsTests: XCTestCase {
  private var directory: URL!
  private var hosts: URL!
  private var flushCount = 0

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    hosts = directory.appendingPathComponent("hosts")
    flushCount = 0
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  private func manager() -> ManagedHosts {
    ManagedHosts(path: hosts.path, flushDNS: { self.flushCount += 1; return [] })
  }

  private func write(_ value: String) throws {
    try Data(value.utf8).write(to: hosts)
  }

  private func read() throws -> String {
    try String(contentsOf: hosts, encoding: .utf8)
  }

  private func desired(_ host: String = "portal.example.test", _ ip: String = "172.20.109.17") -> NSArray {
    [["host": host, "ipv4": ip]] as NSArray
  }

  func testPreservesUnmanagedBytesAndPermissionsAndIsIdempotent() throws {
    let original = "# custom comment\r\n127.0.0.1\tlocalhost\r\n::1 localhost\r\n"
    try write(original)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: hosts.path)
    let before = try FileManager.default.attributesOfItem(atPath: hosts.path)
    let manager = manager()
    let first = manager.reconcile(desired: desired("Portal.Example.Test"))
    XCTAssertTrue(first.changed)
    XCTAssertTrue(first.errors.isEmpty)
    let updated = try read()
    XCTAssertTrue(updated.hasPrefix(original))
    XCTAssertTrue(updated.contains("172.20.109.17\tportal.example.test\n"))
    XCTAssertFalse(manager.reconcile(desired: desired()).changed)
    XCTAssertEqual(try read(), updated)
    XCTAssertEqual(flushCount, 1)
    let after = try FileManager.default.attributesOfItem(atPath: hosts.path)
    for key in [FileAttributeKey.posixPermissions, .ownerAccountID, .groupOwnerAccountID] {
      XCTAssertEqual(before[key] as? NSNumber, after[key] as? NSNumber)
    }
  }

  func testRemovalRestoresOnlyOwnedBlockAndKeepsTrailingLines() throws {
    let prefix = "127.0.0.1 localhost\n"
    let suffix = "# manual after block\n10.1.2.3 untouched.test\n"
    try write(prefix + ManagedHosts.beginMarker + "\n172.20.109.17\tportal.example.test\n" + ManagedHosts.endMarker + "\n" + suffix)
    let result = manager().reconcile(desired: [])
    XCTAssertTrue(result.changed)
    XCTAssertTrue(result.errors.isEmpty)
    XCTAssertEqual(try read(), prefix + suffix)
  }

  func testMatchingManualAliasAlreadySatisfiesMappingWithoutWriting() throws {
    let original = "172.20.109.17 one.test PORTAL.EXAMPLE.TEST # manual alias\n"
    try write(original)
    let result = manager().reconcile(desired: desired())
    XCTAssertFalse(result.changed)
    XCTAssertTrue(result.errors.isEmpty)
    XCTAssertEqual(try read(), original)
    XCTAssertEqual(flushCount, 0)
  }

  func testTrailingDotManualAliasConflictsOrSatisfiesWithoutRewriting() throws {
    for address in ["172.20.109.17", "172.20.109.18", "::1"] {
      let original = "\(address) PORTAL.EXAMPLE.TEST. # manual FQDN\n"
      try write(original)
      let result = manager().reconcile(desired: desired())
      XCTAssertFalse(result.changed)
      XCTAssertEqual(result.errors.isEmpty, address == "172.20.109.17")
      XCTAssertEqual(try read(), original)
    }
    XCTAssertEqual(flushCount, 0)
  }

  func testAtomicReplacementPreservesExtendedAttributes() throws {
    try write("127.0.0.1 localhost\n")
    let value = Data("custom hosts metadata".utf8)
    let written = value.withUnsafeBytes {
      setxattr(hosts.path, "com.netpilot.test", $0.baseAddress, $0.count, 0, 0)
    }
    XCTAssertEqual(written, 0)
    let result = manager().reconcile(desired: desired())
    XCTAssertTrue(result.changed)
    XCTAssertTrue(result.errors.isEmpty)
    var copied = Data(count: value.count)
    let size = copied.withUnsafeMutableBytes {
      getxattr(hosts.path, "com.netpilot.test", $0.baseAddress, $0.count, 0, 0)
    }
    XCTAssertEqual(size, value.count)
    XCTAssertEqual(copied, value)
  }

  func testConflictingManualIPv4OrIPv6RejectsEntireTransaction() throws {
    for address in ["172.20.109.18", "::1"] {
      let original = "\(address) portal.example.test\n"
      try write(original)
      let result = manager().reconcile(desired: desired())
      XCTAssertFalse(result.changed)
      XCTAssertFalse(result.errors.isEmpty)
      XCTAssertEqual(try read(), original)
    }
  }

  func testInvalidOrConflictingPayloadNeverRemovesExistingBlock() throws {
    try write("127.0.0.1 localhost\n")
    let manager = manager()
    XCTAssertTrue(manager.reconcile(desired: desired()).changed)
    let original = try read()
    let invalidPayloads: [NSArray] = [
      [["host": "bad\n127.0.0.1 evil.test", "ipv4": "10.0.0.1"]],
      [["host": "portal.example.test", "ipv4": "10.0.0.1;id"]],
      [["host": "LOCALHOST", "ipv4": "10.0.0.1"]],
      [["host": "portal.example.test", "ipv4": "010.0.0.1"]],
      [["host": "portal.example.test", "ipv4": "10.0.0.1"],
       ["host": "PORTAL.EXAMPLE.TEST", "ipv4": "10.0.0.2"]],
      ["unexpected string"],
    ]
    for payload in invalidPayloads {
      let result = manager.reconcile(desired: payload)
      XCTAssertFalse(result.changed)
      XCTAssertFalse(result.errors.isEmpty)
      XCTAssertEqual(try read(), original)
    }
  }

  func testMalformedMarkersFailClosed() throws {
    for original in [
      ManagedHosts.beginMarker + "\n",
      ManagedHosts.endMarker + "\n",
      ManagedHosts.beginMarker + "\n" + ManagedHosts.beginMarker + "\n" + ManagedHosts.endMarker + "\n",
      "# BEGIN NETPILOT MANAGED HOSTS v2\n",
    ] {
      try write(original)
      XCTAssertFalse(manager().reconcile(desired: desired()).errors.isEmpty)
      XCTAssertEqual(try read(), original)
    }
  }

  func testRejectsSymlinkWithoutChangingTarget() throws {
    let target = directory.appendingPathComponent("target")
    try Data("127.0.0.1 localhost\n".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: hosts, withDestinationURL: target)
    let result = manager().reconcile(desired: desired())
    XCTAssertFalse(result.changed)
    XCTAssertFalse(result.errors.isEmpty)
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "127.0.0.1 localhost\n")
  }

  func testExpiredRequestCannotMutateFile() throws {
    try write("127.0.0.1 localhost\n")
    let result = manager().reconcile(desired: desired(), deadline: Date().timeIntervalSince1970 - 1)
    XCTAssertFalse(result.changed)
    XCTAssertFalse(result.errors.isEmpty)
    XCTAssertEqual(try read(), "127.0.0.1 localhost\n")
  }

  func testExistingBlockUpdatesAndMatchingManualEntryIsNotTakenOver() throws {
    try write("172.20.109.17 portal.example.test\n")
    let manager = manager()
    XCTAssertTrue(manager.reconcile(desired: desired("second.test", "10.0.0.2")).changed)
    let result = manager.reconcile(desired: desired())
    XCTAssertTrue(result.changed)
    XCTAssertTrue(result.errors.isEmpty)
    XCTAssertEqual(try read(), "172.20.109.17 portal.example.test\n")
  }

  func testDNSFlushFailureReportsAppliedFileSeparately() throws {
    try write("127.0.0.1 localhost\n")
    let manager = ManagedHosts(path: hosts.path, flushDNS: { ["DNS refresh failed"] })
    let result = manager.reconcile(desired: desired())
    XCTAssertTrue(result.changed)
    XCTAssertFalse(result.errors.isEmpty)
    XCTAssertTrue(try read().contains("portal.example.test"))
  }
}
