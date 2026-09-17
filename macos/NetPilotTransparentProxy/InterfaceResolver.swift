import Foundation
import Network

final class InterfaceResolver {
  private let monitor = NWPathMonitor()
  private let lock = NSLock()
  private var currentPath: NWPath?

  init() {
    monitor.pathUpdateHandler = { [weak self] path in
      self?.lock.lock()
      self?.currentPath = path
      self?.lock.unlock()
    }
    monitor.start(queue: DispatchQueue(label: "com.netpilot.interface-monitor"))
  }

  func physicalInterface(named name: String) -> NWInterface? {
    guard !name.hasPrefix("utun") else { return nil }
    lock.lock()
    let path = currentPath
    lock.unlock()
    return path?.availableInterfaces.first {
        $0.name == name && ($0.type == .wifi || $0.type == .wiredEthernet)
    }
  }
}
