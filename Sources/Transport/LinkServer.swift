import Foundation
import Network
import SyncProtocol

/// Leader side: accepts followers and advertises the cluster over Bonjour.
public final class LinkServer: @unchecked Sendable {
    public struct Peer: Sendable {
        public var hello: NodeHello?
        public var connection: LinkConnection
    }

    public var onControl: (@Sendable (UUID, ControlMessage) -> Void)?
    public var onPeersChanged: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "syncspeaker.link.server", qos: .userInteractive)
    private let lock = NSLock()
    private var peers: [UUID: Peer] = [:]
    private var listener: NWListener?

    public init() {}

    public func start(serviceName: String, httpPort: UInt16, hostName: String) throws {
        let listener = try NWListener(using: LinkConnection.tcpParameters(), on: NWEndpoint.Port(rawValue: SyncConstants.linkPort)!)
        let txt = NWTXTRecord(["role": "leader", "http": String(httpPort), "host": hostName])
        listener.service = NWListener.Service(name: serviceName, type: SyncConstants.bonjourType, txtRecord: txt)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        let all = lock.withLock { peers.values.map(\.connection) }
        all.forEach { $0.cancel() }
    }

    public var connectedPeers: [Peer] {
        lock.withLock { Array(peers.values) }
    }

    public func broadcast(_ message: ControlMessage) {
        connectedPeers.forEach { $0.connection.send(message) }
    }

    public func send(_ message: ControlMessage, to id: UUID) {
        lock.withLock { peers[id] }?.connection.send(message)
    }

    /// Returns how many peers dropped this chunk due to backpressure.
    @discardableResult
    public func broadcastAudio(_ payload: Data) -> Int {
        connectedPeers.reduce(0) { $0 + ($1.connection.sendAudio(payload) ? 0 : 1) }
    }

    private func accept(_ nw: NWConnection) {
        let link = LinkConnection(connection: nw, queue: queue) { [weak self] link, event in
            guard let self else { return }
            switch event {
            case .ready:
                break
            case .control(let message):
                if case .hello(let hello) = message {
                    self.lock.withLock { self.peers[link.id]?.hello = hello }
                    self.onPeersChanged?()
                }
                self.onControl?(link.id, message)
            case .audio:
                break
            case .closed:
                self.lock.withLock { _ = self.peers.removeValue(forKey: link.id) }
                self.onPeersChanged?()
            }
        }
        lock.withLock { peers[link.id] = Peer(hello: nil, connection: link) }
        link.start()
    }
}
