import Foundation

public struct RouteSpec: Equatable {
  public let destination: String
  public let gateway: String?
  public let interfaceName: String
  public let tag: String

  public init(
    destination: String,
    gateway: String?,
    interfaceName: String,
    tag: String
  ) {
    self.destination = destination
    self.gateway = gateway
    self.interfaceName = interfaceName
    self.tag = tag
  }

  public init?(dictionary: [String: Any]) {
    guard let destination = dictionary["destination"] as? String,
          let interfaceName = dictionary["interfaceName"] as? String,
          let tag = dictionary["tag"] as? String
    else {
      return nil
    }
    self.destination = destination
    self.gateway = dictionary["gateway"] as? String
    self.interfaceName = interfaceName
    self.tag = tag
  }

  public var dictionary: [String: Any] {
    var map: [String: Any] = [
      "destination": destination,
      "interfaceName": interfaceName,
      "tag": tag,
    ]
    if let gateway, !gateway.isEmpty {
      map["gateway"] = gateway
    }
    return map
  }

  public static func validate(_ spec: RouteSpec) -> String? {
    if !spec.tag.hasPrefix("netpilot:") {
      return "tag must start with netpilot:"
    }
    if !isValidDestination(spec.destination) {
      return "invalid destination \(spec.destination)"
    }
    if let gateway = spec.gateway, !gateway.isEmpty, !isValidIPv4(gateway) {
      return "invalid gateway \(gateway)"
    }
    if !isValidBSDName(spec.interfaceName) {
      return "invalid interface \(spec.interfaceName)"
    }
    return nil
  }

  public static func isValidIPv4(_ value: String) -> Bool {
    let parts = value.split(separator: ".")
    guard parts.count == 4 else { return false }
    for part in parts {
      guard let n = Int(part), (0...255).contains(n) else { return false }
    }
    return true
  }

  public static func isValidDestination(_ value: String) -> Bool {
    let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
    guard pieces.count == 2,
          let prefix = Int(pieces[1]),
          (0...32).contains(prefix)
    else {
      return false
    }
    return isValidIPv4(String(pieces[0]))
  }

  public static func isValidBSDName(_ value: String) -> Bool {
    let regex = try? NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9]*$")
    let range = NSRange(location: 0, length: value.utf16.count)
    return regex?.firstMatch(in: value, range: range) != nil
  }
}
