import Foundation

@objc public protocol NetPilotXPCProtocol {
  func ping(withReply reply: @escaping (Bool) -> Void)
  func listManagedRoutes(withReply reply: @escaping (NSArray) -> Void)
  func reconcileDesired(
    _ desired: NSArray,
    withReply reply: @escaping (NSDictionary) -> Void
  )
}

public enum NetPilotXPCConstants {
  public static let machServiceName = "com.netpilot.netpilotDesktop.helper"
  public static let helperBundleId = "com.netpilot.netpilotDesktop.helper"
  public static let appBundleId = "com.netpilot.netpilotDesktop"
  public static let launchdPlistName = "com.netpilot.netpilotDesktop.helper.plist"
}
