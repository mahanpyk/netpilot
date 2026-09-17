import Foundation
import Network
import NetworkExtension

final class TCPFlowRelay {
  private let flow: NEAppProxyTCPFlow
  private let connection: NWConnection
  private let queue: DispatchQueue
  private let onBytes: (Int, Int) -> Void
  private let onClose: () -> Void
  private var closed = false

  init(
    flow: NEAppProxyTCPFlow,
    connection: NWConnection,
    queue: DispatchQueue,
    onBytes: @escaping (Int, Int) -> Void,
    onClose: @escaping () -> Void
  ) {
    self.flow = flow
    self.connection = connection
    self.queue = queue
    self.onBytes = onBytes
    self.onClose = onClose
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.flow.open(withLocalEndpoint: nil) { error in
          if let error { self.close(error); return }
          self.readFromFlow()
          self.readFromNetwork()
        }
      case .failed(let error): self.close(error)
      case .cancelled: self.close(nil)
      default: break
      }
    }
    connection.start(queue: queue)
  }

  private func readFromFlow() {
    flow.readData { [weak self] data, error in
      guard let self, !self.closed else { return }
      if let error { self.close(error); return }
      guard let data, !data.isEmpty else {
        self.connection.send(content: nil, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in })
        return
      }
      self.onBytes(data.count, 0)
      self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
        if let error { self?.close(error) } else { self?.readFromFlow() }
      })
    }
  }

  private func readFromNetwork() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
      guard let self, !self.closed else { return }
      if let error { self.close(error); return }
      if let data, !data.isEmpty {
        self.onBytes(0, data.count)
        self.flow.write(data) { [weak self] error in
          if let error { self?.close(error) }
          else if complete { self?.flow.closeReadWithError(nil) }
          else { self?.readFromNetwork() }
        }
      } else if complete {
        self.flow.closeReadWithError(nil)
      } else {
        self.readFromNetwork()
      }
    }
  }

  private func close(_ error: Error?) {
    guard !closed else { return }
    closed = true
    flow.closeReadWithError(error)
    flow.closeWriteWithError(error)
    connection.cancel()
    onClose()
  }
}

final class UDPFlowRelay {
  private let flow: NEAppProxyUDPFlow
  private let interface: NWInterface
  private let queue: DispatchQueue
  private let onBytes: (Int, Int) -> Void
  private let onClose: () -> Void
  private var connections: [String: NWConnection] = [:]
  private var closed = false

  init(
    flow: NEAppProxyUDPFlow,
    interface: NWInterface,
    queue: DispatchQueue,
    onBytes: @escaping (Int, Int) -> Void,
    onClose: @escaping () -> Void
  ) {
    self.flow = flow
    self.interface = interface
    self.queue = queue
    self.onBytes = onBytes
    self.onClose = onClose
  }

  func start() {
    flow.open(withLocalEndpoint: nil) { [weak self] error in
      guard let self else { return }
      if let error { self.close(error); return }
      self.readDatagrams()
    }
  }

  private func readDatagrams() {
    flow.readDatagrams { [weak self] datagrams, endpoints, error in
      guard let self, !self.closed else { return }
      if let error { self.close(error); return }
      for (data, endpoint) in zip(datagrams ?? [], endpoints ?? []) {
        guard let hostEndpoint = endpoint as? NWHostEndpoint else { continue }
        let key = "\(hostEndpoint.hostname):\(hostEndpoint.port)"
        let connection = self.connections[key] ?? self.makeConnection(hostEndpoint, key: key)
        self.onBytes(data.count, 0)
        connection.send(content: data, completion: .contentProcessed { error in
          if let error { NSLog("[NetPilot App Routing] UDP send failed: %@", error.localizedDescription) }
        })
      }
      self.readDatagrams()
    }
  }

  private func makeConnection(_ endpoint: NWHostEndpoint, key: String) -> NWConnection {
    let parameters = NWParameters.udp
    parameters.requiredInterface = interface
    let connection = NWConnection(
      host: NWEndpoint.Host(endpoint.hostname),
      port: NWEndpoint.Port(endpoint.port) ?? .any,
      using: parameters
    )
    connections[key] = connection
    connection.stateUpdateHandler = { [weak self] state in
      if case .ready = state { self?.receive(connection, endpoint: endpoint) }
      if case .failed(let error) = state {
        NSLog("[NetPilot App Routing] UDP connection failed: %@", error.localizedDescription)
      }
    }
    connection.start(queue: queue)
    return connection
  }

  private func receive(_ connection: NWConnection, endpoint: NWHostEndpoint) {
    connection.receiveMessage { [weak self] data, _, _, error in
      guard let self, !self.closed else { return }
      if let data, !data.isEmpty {
        self.onBytes(0, data.count)
        self.flow.writeDatagrams([data], sentBy: [endpoint]) { error in
          if let error { NSLog("[NetPilot App Routing] UDP write failed: %@", error.localizedDescription) }
        }
      }
      if error == nil { self.receive(connection, endpoint: endpoint) }
    }
  }

  private func close(_ error: Error?) {
    guard !closed else { return }
    closed = true
    flow.closeReadWithError(error)
    flow.closeWriteWithError(error)
    connections.values.forEach { $0.cancel() }
    connections.removeAll()
    onClose()
  }
}
