import Foundation
import SystemConfiguration

final class NetworkInventoryService {
  private var store: SCDynamicStore?
  private var onChange: (() -> Void)?

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

  func resolveHost(_ host: String, interfaceId: String?) -> [String: Any] {
    var hints = addrinfo(
      ai_flags: AI_ADDRCONFIG,
      ai_family: AF_INET,
      ai_socktype: SOCK_STREAM,
      ai_protocol: 0,
      ai_addrlen: 0,
      ai_canonname: nil,
      ai_addr: nil,
      ai_next: nil
    )
    var resultPtr: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, nil, &hints, &resultPtr)
    defer {
      if let resultPtr {
        freeaddrinfo(resultPtr)
      }
    }
    guard status == 0, let first = resultPtr else {
      return ["ips": [String]()]
    }

    var ips: [String] = []
    var cursor: UnsafeMutablePointer<addrinfo>? = first
    while let info = cursor?.pointee {
      if info.ai_family == AF_INET, let addr = info.ai_addr {
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let g = getnameinfo(
          addr,
          socklen_t(info.ai_addrlen),
          &hostname,
          socklen_t(hostname.count),
          nil,
          0,
          NI_NUMERICHOST
        )
        if g == 0 {
          let ip = String(cString: hostname)
          if !ips.contains(ip) {
            ips.append(ip)
          }
        }
      }
      cursor = info.ai_next
    }
    // interfaceId reserved for future scoped DNS; included for contract stability
    _ = interfaceId
    return ["ips": ips]
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
