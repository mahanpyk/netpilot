import Darwin
import Foundation

struct HostMapping: Equatable {
  let host: String
  let ipv4: String

  init?(dictionary: [String: Any]) {
    guard let host = dictionary["host"] as? String,
          let ipv4 = dictionary["ipv4"] as? String,
          Self.validHost(host), Self.validIPv4(ipv4) else { return nil }
    self.host = host.lowercased()
    self.ipv4 = ipv4
  }

  private static func validHost(_ host: String) -> Bool {
    guard !host.isEmpty, host.utf8.count <= 253,
          host != "localhost", host.lowercased() != "broadcasthost",
          !host.lowercased().hasSuffix(".localhost"),
          !validIPv4(host) else { return false }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    return labels.allSatisfy { label in
      !label.isEmpty && label.utf8.count <= 63 &&
        label.first != "-" && label.last != "-" &&
        label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) ||
          (48...57).contains($0) || $0 == 45 }
    } && host.lowercased() != "localhost"
  }

  private static func validIPv4(_ value: String) -> Bool {
    let octets = value.split(separator: ".", omittingEmptySubsequences: false)
    return octets.count == 4 && octets.allSatisfy {
      !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } &&
        ($0.count == 1 || $0.first != "0") && Int($0).map { (0...255).contains($0) } == true
    }
  }
}

struct HostsReconcileResult {
  var changed = false
  var errors: [String] = []
  var dictionary: [String: Any] {
    ["ok": errors.isEmpty, "changed": changed, "errors": errors]
  }
}

/// Owns only the explicit NetPilot block; all other hosts bytes stay intact.
/// The helper uses the fixed default path. Tests may supply a temporary file.
final class ManagedHosts {
  static let beginMarker = "# BEGIN NETPILOT MANAGED HOSTS v1"
  static let endMarker = "# END NETPILOT MANAGED HOSTS v1"
  private let path: String
  private let flushDNS: () -> [String]
  private let lock = NSLock()
  private static let maxBytes = 1_048_576

  init(path: String = "/etc/hosts", flushDNS: @escaping () -> [String] = ManagedHosts.flushSystemDNS) {
    self.path = path
    self.flushDNS = flushDNS
  }

  func reconcile(desired: NSArray, deadline: Double = Date.distantFuture.timeIntervalSince1970) -> HostsReconcileResult {
    lock.lock()
    defer { lock.unlock() }
    guard deadline.isFinite, Date().timeIntervalSince1970 < deadline else {
      return HostsReconcileResult(errors: ["Host mapping request expired; no changes made."])
    }
    guard desired.count <= 1024 else {
      return HostsReconcileResult(errors: ["Too many managed host mappings (maximum 1024)."])
    }
    var mappings: [String: String] = [:]
    for item in desired {
      guard let dictionary = item as? [String: Any],
            let mapping = HostMapping(dictionary: dictionary) else {
        return HostsReconcileResult(errors: ["Invalid host mapping: expected a hostname and canonical IPv4 address."])
      }
      if let existing = mappings[mapping.host], existing != mapping.ipv4 {
        return HostsReconcileResult(errors: ["Conflicting IPv4 mappings for \(mapping.host)."])
      }
      mappings[mapping.host] = mapping.ipv4
    }

    do {
      // O_NOFOLLOW and fstat prevent editing symlinks, devices or FIFOs.
      let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
      guard descriptor >= 0 else { throw failure("Cannot safely open hosts file") }
      defer { close(descriptor) }
      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_size >= 0, metadata.st_size <= Self.maxBytes else {
        throw failure("Hosts file must be a regular file of at most 1 MB")
      }
      let original = try readData(descriptor)
      guard let content = String(data: original, encoding: .utf8) else {
        throw failure("Hosts file is not valid UTF-8; no changes made")
      }
      let replacement = try Self.updatedContent(content, desired: mappings)
      let updated = Data(replacement.utf8)
      guard updated != original else { return HostsReconcileResult() }
      guard updated.count <= Self.maxBytes else { throw failure("Resulting hosts file exceeds 1 MB") }
      try replaceAtomically(updated, expectedData: original, metadata: metadata,
                            originalDescriptor: descriptor, deadline: deadline)
      return HostsReconcileResult(changed: true, errors: flushDNS())
    } catch {
      return HostsReconcileResult(errors: [error.localizedDescription])
    }
  }

  private static func updatedContent(_ original: String, desired: [String: String]) throws -> String {
    // Keep the original line endings and every byte outside our markers.
    var lines: [String] = []
    var cursor = original.startIndex
    while cursor < original.endIndex {
      let end = original[cursor...].firstIndex(of: "\n").map { original.index(after: $0) } ?? original.endIndex
      lines.append(String(original[cursor..<end]))
      cursor = end
    }
    var start: Int?
    var end: Int?
    for (index, line) in lines.enumerated() {
      let text = line.trimmingCharacters(in: .newlines)
      if text == beginMarker {
        guard start == nil, end == nil else { throw invalidBlock() }
        start = index
      } else if text == endMarker {
        guard start != nil, end == nil else { throw invalidBlock() }
        end = index
      } else if text.contains("NETPILOT MANAGED HOSTS") {
        throw invalidBlock()
      }
    }
    guard (start == nil) == (end == nil) else { throw invalidBlock() }
    var remaining = desired
    for (index, line) in lines.enumerated() {
      if let start, let end, (start...end).contains(index) { continue }
      let uncommented = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
      let fields = uncommented.split(whereSeparator: { $0.isWhitespace })
      guard fields.count >= 2 else { continue }
      for hostname in fields.dropFirst() {
        // DNS treats a final root dot as the same hostname. Match the native
        // resolver's canonical form before checking unmanaged aliases.
        let host = hostname.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let address = desired[host] else { continue }
        guard fields[0] == address else {
          throw NSError(domain: "NetPilotHosts", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "\(host) already has a different manual hosts entry (\(fields[0])). Update or remove that entry first.",
          ])
        }
        remaining.removeValue(forKey: host)
      }
    }
    let block = remaining.isEmpty ? "" : beginMarker + "\n" + remaining.keys.sorted().map {
      "\(remaining[$0]!)\t\($0)\n"
    }.joined() + endMarker + "\n"
    if let start, let end {
      return lines[..<start].joined() + block + lines[(end + 1)...].joined()
    }
    guard !block.isEmpty else { return original }
    return original + (original.isEmpty || original.hasSuffix("\n") ? "" : "\n") + block
  }

  private func readData(_ descriptor: Int32) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      if count == 0 { return result }
      if count < 0 {
        if errno == EINTR { continue }
        throw failure("Cannot read hosts file")
      }
      result.append(contentsOf: buffer.prefix(count))
      guard result.count <= Self.maxBytes else { throw failure("Hosts file exceeds 1 MB") }
    }
  }

  private func replaceAtomically(_ data: Data, expectedData: Data, metadata: stat,
                                 originalDescriptor: Int32, deadline: Double) throws {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
    var template = Array((directory + "/.netpilot-hosts.XXXXXX").utf8CString)
    let temporary = mkstemp(&template)
    guard temporary >= 0 else { throw failure("Cannot create hosts replacement") }
    let temporaryPath = String(cString: template)
    defer { close(temporary); unlink(temporaryPath) }
    guard fchown(temporary, metadata.st_uid, metadata.st_gid) == 0,
          fchmod(temporary, metadata.st_mode & 0o7777) == 0 else {
      throw failure("Cannot preserve hosts file owner and permissions")
    }
    guard fcopyfile(originalDescriptor, temporary, nil,
                    copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)) == 0 else {
      throw failure("Cannot preserve hosts file access controls and extended attributes")
    }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = write(temporary, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 {
          if errno == EINTR { continue }
          throw failure("Cannot write hosts replacement")
        }
        guard count > 0 else { throw failure("Incomplete hosts replacement") }
        offset += count
      }
    }
    guard fsync(temporary) == 0 else { throw failure("Cannot sync hosts replacement") }
    // Refuse to replace a concurrently edited/replaced hosts file.
    let current = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard current >= 0 else { throw failure("Hosts file changed during update; retry") }
    defer { close(current) }
    var currentMetadata = stat()
    guard fstat(current, &currentMetadata) == 0,
          currentMetadata.st_mode & S_IFMT == S_IFREG,
          currentMetadata.st_ino == metadata.st_ino,
          currentMetadata.st_dev == metadata.st_dev,
          currentMetadata.st_uid == metadata.st_uid,
          currentMetadata.st_gid == metadata.st_gid,
          currentMetadata.st_mode == metadata.st_mode,
          currentMetadata.st_flags == metadata.st_flags,
          currentMetadata.st_ctimespec.tv_sec == metadata.st_ctimespec.tv_sec,
          currentMetadata.st_ctimespec.tv_nsec == metadata.st_ctimespec.tv_nsec,
          try readData(current) == expectedData else {
      throw failure("Hosts file changed during update; retry")
    }
    guard Date().timeIntervalSince1970 < deadline else {
      throw failure("Host mapping request expired; no changes made")
    }
    guard rename(temporaryPath, path) == 0 else { throw failure("Cannot atomically replace hosts file") }
  }

  private func failure(_ message: String) -> Error {
    NSError(domain: "NetPilotHosts", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: message])
  }

  private static func invalidBlock() -> Error {
    NSError(domain: "NetPilotHosts", code: 1, userInfo: [
      NSLocalizedDescriptionKey: "Managed hosts markers are malformed; no changes made.",
    ])
  }

  static func flushSystemDNS() -> [String] {
    var errors: [String] = []
    // Fixed executables/arguments only, bounded independently of system DNS.
    for (executable, arguments) in [
      ("/usr/bin/dscacheutil", ["-flushcache"]),
      ("/usr/bin/killall", ["-HUP", "mDNSResponder"]),
    ] {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      let completion = DispatchSemaphore(value: 0)
      process.terminationHandler = { _ in completion.signal() }
      do {
        try process.run()
        if completion.wait(timeout: .now() + 1) == .timedOut {
          process.terminate()
          if completion.wait(timeout: .now() + 0.2) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
          }
          errors.append("Hosts saved, but DNS cache refresh timed out.")
        } else if process.terminationStatus != 0 {
          errors.append("Hosts saved, but DNS cache refresh failed.")
        }
      } catch {
        errors.append("Hosts saved, but DNS cache refresh could not run.")
      }
    }
    return errors
  }
}
