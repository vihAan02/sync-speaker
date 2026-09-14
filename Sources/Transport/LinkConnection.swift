import Foundation
import Network
import SyncProtocol

/// One framed TCP connection between leader and follower.
public final class LinkConnection: @unchecked Sendable {
    public enum Event: Sendable {
        case ready
        case control(ControlMessage)
        case audio(Data)
        case closed(String?)
    }

    public let id = UUID()
    public let connection: NWConnection
    private let queue: DispatchQueue
    private let onEvent: @Sendable (LinkConnection, Event) -> Void
    private let lock = NSLock()
    private var pendingBytes = 0
    private var closed = false

    /// Audio frames are skipped while this many bytes are still unsent (receiver zero-fills the gap).
    public static let audioBackpressureBytes = 1_500_000

    public init(connection: NWConnection, queue: DispatchQueue, onEvent: @escaping @Sendable (LinkConnection, Event) -> Void) {
        self.connection = connection
        self.queue = queue
        self.onEvent = onEvent
    }

    public static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVoice
        params.includePeerToPeer = true
        return params
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onEvent(self, .ready)
                self.readPrefix()
            case .failed(let error):
                self.finish(error.localizedDescription)
            case .cancelled:
                self.finish(nil)
            case .waiting(let error):
                self.finish("waiting: \(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func cancel() {
        connection.cancel()
    }

    /// The remote host, once connected.
    public var remoteHost: NWEndpoint.Host? {
        if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint { return host }
        if case .hostPort(let host, _) = connection.endpoint { return host }
        return nil
    }

    public func send(_ message: ControlMessage) {
        guard let frame = try? LinkFrame.encodeControl(message) else { return }
        write(frame)
    }

    /// Returns false if the audio frame was dropped because the connection is backed up.
    @discardableResult
    public func sendAudio(_ payload: Data) -> Bool {
        let backedUp = lock.withLock { pendingBytes > Self.audioBackpressureBytes }
        if backedUp { return false }
        write(LinkFrame.encode(.audio, payload: payload))
        return true
    }

    private func write(_ frame: Data) {
        lock.withLock { pendingBytes += frame.count }
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.withLock { self.pendingBytes -= frame.count }
            if let error { self.finish(error.localizedDescription) }
        })
    }

    private func finish(_ reason: String?) {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        connection.cancel()
        onEvent(self, .closed(reason))
    }

    private func readPrefix() {
        connection.receive(minimumIncompleteLength: LinkFrame.prefixSize, maximumLength: LinkFrame.prefixSize) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { return self.finish(error.localizedDescription) }
            guard let data, let length = LinkFrame.length(fromPrefix: data) else {
                return self.finish(isComplete ? nil : "bad frame prefix")
            }
            self.readBody(length: length)
        }
    }

    private func readBody(length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { return self.finish(error.localizedDescription) }
            guard let data, data.count == length else { return self.finish(isComplete ? nil : "short frame") }
            let payload = data.dropFirst()
            switch LinkFrame.FrameType(rawValue: data[data.startIndex]) {
            case .control:
                if let message = try? JSONDecoder().decode(ControlMessage.self, from: payload) {
                    self.onEvent(self, .control(message))
                }
            case .audio:
                self.onEvent(self, .audio(Data(payload)))
            case nil:
                break
            }
            self.readPrefix()
        }
    }
}
