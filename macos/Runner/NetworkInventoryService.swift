import Foundation
import SystemConfiguration
import dnssd

final class NetworkInventoryService {
  private var store: SCDynamicStore?
  private var onChange: (() -> Void)?
  private let hostResolver = IPv4HostResolver()

  func startMonitoring(onChange: @escaping () -> Void) {
    self.onChange = onChange
    let callback: SCDynamicStoreCallBack = { _, _, info in
      guard let info else { return }
      let service = Unmanaged<NetworkInventoryService>.fromOpaque(info).takeUnretainedValue()
      service.onChange?()
    }
    var context = SCDynamicStoreContext(
      version: 0,
      info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    guard let store = SCDynamicStoreCreate(
      nil,
      "com.netpilot.netpilotDesktop.inventory" as CFString,
      callback,
      &context
    ) else {
      return
    }
    self.store = store
    let keys = [
      "State:/Network/Global/IPv4" as CFString,
      "State:/Network/Interface" as CFString,
    ] as CFArray
    let patterns = [
      "State:/Network/Service/.*/IPv4" as CFString,
      "State:/Network/Service/.*/DNS" as CFString,
    ] as CFArray
    SCDynamicStoreSetNotificationKeys(store, keys, patterns)
    let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0)
    if let source {
      CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }
  }

  func listInterfaces() -> [[String: Any]] {
    let defaultInterface = currentDefaultInterface()
    var results: [[String: Any]] = []

    guard let store = SCDynamicStoreCreate(
      nil,
      "com.netpilot.netpilotDesktop.inventory.query" as CFString,
      nil,
      nil
    ) else {
      return results
    }

    // Enumerate IPv4 services
    let pattern = "State:/Network/Service/.*/IPv4" as CFString
    guard let keys = SCDynamicStoreCopyKeyList(store, pattern) as? [String] else {
      return results
    }

    for key in keys {
      guard let ipv4 = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
            let interfaceName = ipv4["InterfaceName"] as? String
      else {
        continue
      }
      let addresses = (ipv4["Addresses"] as? [String]) ?? []
      let router = ipv4["Router"] as? String
      let serviceId = key
        .replacingOccurrences(of: "State:/Network/Service/", with: "")
        .replacingOccurrences(of: "/IPv4", with: "")

      let dnsKey = "State:/Network/Service/\(serviceId)/DNS" as CFString
      let dnsValue = SCDynamicStoreCopyValue(store, dnsKey) as? [String: Any]
      let dnsServers = (dnsValue?["ServerAddresses"] as? [String]) ?? []

      let setupKey = "Setup:/Network/Service/\(serviceId)" as CFString
      let setup = SCDynamicStoreCopyValue(store, setupKey) as? [String: Any]
      let userDefinedName = (setup?["UserDefinedName"] as? String) ?? interfaceName

      let kind = classify(interfaceName: interfaceName, displayName: userDefinedName)
      let isDefault = interfaceName == defaultInterface
      let active = !addresses.isEmpty

      results.append([
        "id": interfaceName,
        "name": userDefinedName,
        "interfaceName": interfaceName,
        "kind": kind,
        "ipv4Addresses": addresses,
        "gateway": router as Any,
        "dnsServers": dnsServers,
        "isDefaultRoute": isDefault,
        "isActive": active,
      ])
    }

    // Deduplicate by interface name (keep first)
    var seen = Set<String>()
    results = results.filter { item in
      guard let name = item["interfaceName"] as? String else { return false }
      if seen.contains(name) { return false }
      seen.insert(name)
      return true
    }

    return results.sorted { lhs, rhs in
      let lDefault = (lhs["isDefaultRoute"] as? Bool) ?? false
      let rDefault = (rhs["isDefaultRoute"] as? Bool) ?? false
      if lDefault != rDefault { return lDefault && !rDefault }
      let lName = (lhs["name"] as? String) ?? ""
      let rName = (rhs["name"] as? String) ?? ""
      return lName < rName
    }
  }

  func resolveHost(
    _ host: String,
    interfaceId: String?,
    completion: @escaping ([String: Any]) -> Void
  ) {
    hostResolver.resolve(host, interfaceId: interfaceId) { ips in
      completion(["ips": ips])
    }
  }

  private func currentDefaultInterface() -> String? {
    guard let store = SCDynamicStoreCreate(
      nil,
      "com.netpilot.netpilotDesktop.default" as CFString,
      nil,
      nil
    ) else {
      return nil
    }
    let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
    return value?["PrimaryInterface"] as? String
  }

  private func classify(interfaceName: String, displayName: String) -> String {
    let blob = (interfaceName + " " + displayName).lowercased()
    if blob.contains("wi-fi") || blob.contains("wifi") || blob.contains("airport") || interfaceName.hasPrefix("en") && displayName.lowercased().contains("wi") {
      if displayName.lowercased().contains("wi-fi") || displayName.lowercased().contains("wifi") {
        return "wifi"
      }
    }
    if displayName.lowercased().contains("ethernet") ||
        displayName.lowercased().contains("usb") ||
        displayName.lowercased().contains("thunderbolt") ||
        displayName.lowercased().contains("lan") {
      return "ethernet"
    }
    if interfaceName.hasPrefix("en") {
      // Heuristic: primary en0 often Wi-Fi on Apple silicon laptops
      if interfaceName == "en0" { return "wifi" }
      return "ethernet"
    }
    return "other"
  }
}

// All DNS work, callbacks, and cancellation share this serial queue. In
// particular, never block the Flutter/macOS main thread inside getaddrinfo.
protocol IPv4DNSQuery: AnyObject {
  func start(
    host: String,
    interfaceIndex: UInt32,
    reply: @escaping (DNSServiceFlags, DNSServiceErrorType, String?) -> Void
  ) -> DNSServiceErrorType
  func cancel()
}

final class IPv4HostResolver {
  private let queue = DispatchQueue(label: "com.netpilot.ipv4-dns")
  private let timeout: TimeInterval
  private let hostsContents: () -> String?
  private let makeQuery: (DispatchQueue) -> IPv4DNSQuery

  init(
    timeout: TimeInterval = 6,
    hostsContents: @escaping () -> String? = {
      try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)
    },
    makeQuery: @escaping (DispatchQueue) -> IPv4DNSQuery = { DNSServiceIPv4Query(queue: $0) }
  ) {
    self.timeout = timeout
    self.hostsContents = hostsContents
    self.makeQuery = makeQuery
  }

  func resolve(
    _ host: String,
    interfaceId: String?,
    completion: @escaping ([String]) -> Void
  ) {
    queue.async {
      let local = Self.hostsAddresses(host: host, contents: self.hostsContents() ?? "")
      if !local.isEmpty {
        DispatchQueue.main.async { completion(local) }
        return
      }
      var address = in_addr()
      if host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 {
        DispatchQueue.main.async { completion([host]) }
        return
      }
      let interfaceIndex: UInt32
      if let interfaceId, !interfaceId.isEmpty {
        interfaceIndex = if_nametoindex(interfaceId)
        guard interfaceIndex != 0 else {
          DispatchQueue.main.async { completion([]) }
          return
        }
      } else {
        interfaceIndex = 0
      }
      let request = IPv4ResolutionRequest(
        queue: self.queue,
        query: self.makeQuery(self.queue),
        timeout: self.timeout,
        completion: completion
      )
      request.start(host: host, interfaceIndex: interfaceIndex)
    }
  }

  // Hosts entries must retain precedence over scoped corporate DNS so NetPilot
  // routes the same IPv4 address that browsers receive from the system resolver.
  static func hostsAddresses(host: String, contents: String) -> [String] {
    func normalized(_ value: String) -> String {
      value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
    let name = normalized(host)
    guard !name.isEmpty else { return [] }
    var addresses: [String] = []
    for line in contents.split(whereSeparator: \.isNewline) {
      let fields = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        .split(whereSeparator: \.isWhitespace).map(String.init)
      guard fields.count >= 2,
            fields.dropFirst().contains(where: { normalized($0) == name }) else { continue }
      var address = in_addr()
      guard fields[0].withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { continue }
      if !addresses.contains(fields[0]) { addresses.append(fields[0]) }
    }
    return addresses
  }
}

private final class IPv4ResolutionRequest {
  private let queue: DispatchQueue
  private let query: IPv4DNSQuery
  private let timeout: TimeInterval
  private var completion: (([String]) -> Void)?
  private var ips: [String] = []

  init(
    queue: DispatchQueue,
    query: IPv4DNSQuery,
    timeout: TimeInterval,
    completion: @escaping ([String]) -> Void
  ) {
    self.queue = queue
    self.query = query
    self.timeout = timeout
    self.completion = completion
  }

  func start(host: String, interfaceIndex: UInt32) {
    // This deadline retains the request until completion and bounds silent DNS
    // servers. Deallocation on the query's queue also prevents late callbacks.
    queue.asyncAfter(deadline: .now() + timeout) { self.finish() }
    let status = query.start(host: host, interfaceIndex: interfaceIndex) { [weak self] flags, error, ip in
      guard let self, self.completion != nil else { return }
      if error != kDNSServiceErr_NoError { self.finish(); return }
      if let ip, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, !self.ips.contains(ip) {
        self.ips.append(ip)
      }
      if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { self.finish() }
    }
    if status != kDNSServiceErr_NoError { finish() }
  }

  private func finish() {
    guard let completion else { return }
    self.completion = nil
    query.cancel()
    let result = ips.sorted()
    DispatchQueue.main.async { completion(result) }
  }
}

private final class DNSServiceIPv4Query: IPv4DNSQuery {
  private let queue: DispatchQueue
  private var service: DNSServiceRef?
  private var reply: ((DNSServiceFlags, DNSServiceErrorType, String?) -> Void)?

  init(queue: DispatchQueue) { self.queue = queue }

  func start(
    host: String,
    interfaceIndex: UInt32,
    reply: @escaping (DNSServiceFlags, DNSServiceErrorType, String?) -> Void
  ) -> DNSServiceErrorType {
    self.reply = reply
    let status = DNSServiceGetAddrInfo(
      &service,
      DNSServiceFlags(kDNSServiceFlagsTimeout),
      interfaceIndex,
      DNSServiceProtocol(kDNSServiceProtocol_IPv4),
      host,
      { _, flags, _, error, _, address, _, context in
        guard let context else { return }
        let query = Unmanaged<DNSServiceIPv4Query>.fromOpaque(context).takeUnretainedValue()
        var ip: String?
        if error == kDNSServiceErr_NoError, let address, address.pointee.sa_family == AF_INET {
          var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
          if getnameinfo(
            address, socklen_t(MemoryLayout<sockaddr_in>.size),
            &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST
          ) == 0 {
            ip = String(cString: hostname)
          }
        }
        query.reply?(flags, error, ip)
      },
      Unmanaged.passUnretained(self).toOpaque()
    )
    guard status == kDNSServiceErr_NoError, let service else { return status }
    return DNSServiceSetDispatchQueue(service, queue)
  }

  func cancel() {
    reply = nil
    if let service { DNSServiceRefDeallocate(service) }
    service = nil
  }
}
