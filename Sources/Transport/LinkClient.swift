import Foundation
import Network
import SyncProtocol

/// Follower side: finds the leader over Bonjour (or a fixed host), keeps the link up, reconnects.
public final class LinkClient: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case searching
        case connecting(String)
        case connected(String)
    }

    public var onControl: (@Sendable (ControlMessage) -> Void)?
    public var onAudio: (@Sendable (Data) -> Void)?
    /// Called with the leader's host when connected, nil when disconnected.
    public var onLeaderHost: (@Sendable (String?) -> Void)?
    public var onStateChange: (@Sendable (State) -> Void)?

    private let queue = DispatchQueue(label: "syncspeaker.link.client", qos: .userInteractive)
    private let hello: NodeHello
    private let fixedHost: String?
    private var browser: NWBrowser?
    private var link: LinkConnection?
    private var running = false
    public private(set) var state: State = .searching {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    public init(hello: NodeHello, fixedHost: String? = nil) {
        self.hello = hello
        self.fixedHost = fixedHost
    }

    public func start() {
        queue.async {
            self.running = true
            self.connectNext()
        }
    }

    public func stop() {
        queue.async {
            self.running = false
            self.browser?.cancel()
            self.browser = nil
            self.link?.cancel()
            self.link = nil
        }
    }

    public func send(_ message: ControlMessage) {
        queue.async { self.link?.send(message) }
    }

    private func connectNext() {
        guard running, link == nil else { return }
        if let fixedHost {
            connect(to: .hostPort(host: NWEndpoint.Host(fixedHost), port: NWEndpoint.Port(rawValue: SyncConstants.linkPort)!),
                    label: fixedHost)
        } else {
            browse()
        }
    }

    private func browse() {
        state = .searching
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: SyncConstants.bonjourType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.link == nil else { return }
            let leader = results.first { result in
                if case .bonjour(let txt) = result.metadata { return txt["role"] == "leader" }
                return false
            }
            guard let leader else { return }
            var label = "leader"
            if case .service(let name, _, _, _) = leader.endpoint { label = name }
            self.browser?.cancel()
            self.browser = nil
            self.connect(to: leader.endpoint, label: label)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func connect(to endpoint: NWEndpoint, label: String) {
        state = .connecting(label)
        let nw = NWConnection(to: endpoint, using: LinkConnection.tcpParameters())
        let link = LinkConnection(connection: nw, queue: queue) { [weak self] link, event in
            guard let self else { return }
            switch event {
            case .ready:
                link.send(.hello(self.hello))
                self.state = .connected(label)
                self.onLeaderHost?(link.remoteHost.map(Self.hostString))
            case .control(let message):
                self.onControl?(message)
            case .audio(let data):
                self.onAudio?(data)
            case .closed:
                self.queue.async {
                    guard self.link === link else { return }
                    self.link = nil
                    self.onLeaderHost?(nil)
                    self.state = .searching
                    self.queue.asyncAfter(deadline: .now() + 2) { self.connectNext() }
                }
            }
        }
        self.link = link
        link.start()
    }

    static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _): name
        case .ipv4(let address): "\(address)"
        case .ipv6(let address): "\(address)"
        @unknown default: "\(host)"
        }
    }
}
