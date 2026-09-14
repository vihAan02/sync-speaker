import Foundation
import Network
import Observation
import SyncProtocol

/// A leader Mac found on the LAN.
struct DiscoveredLeader: Identifiable, Hashable {
    var id: String { host }
    var name: String
    var host: String
    var httpPort: Int
}

/// Finds leaders over Bonjour and holds the `/ws/phone` WebSocket.
@MainActor
@Observable
final class LeaderConnection {
    enum Status: Equatable {
        case disconnected
        case connecting(String)
        case connected(String)
    }

    private(set) var leaders: [DiscoveredLeader] = []
    private(set) var status: Status = .disconnected
    private(set) var state: UIState?
    private(set) var current: DiscoveredLeader?

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private let session = URLSession(configuration: .default)
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private var reconnectWork: Task<Void, Never>?

    var webURL: URL? {
        current.flatMap { URL(string: "http://\($0.host):\($0.httpPort)") }
    }

    func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: SyncConstants.bonjourType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [DiscoveredLeader] = results.compactMap { result in
                guard case .bonjour(let txt) = result.metadata, txt["role"] == "leader",
                      case .service(let name, _, _, _) = result.endpoint else { return nil }
                let host = txt["host"] ?? "\(name).local"
                return DiscoveredLeader(name: name, host: host, httpPort: Int(txt["http"] ?? "") ?? Int(SyncConstants.httpPort))
            }
            Task { @MainActor in
                guard let self else { return }
                self.leaders = found
                // Auto-connect to the only leader on the network.
                if self.current == nil, found.count == 1 { self.connect(to: found[0]) }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func connect(to leader: DiscoveredLeader) {
        disconnect()
        current = leader
        status = .connecting(leader.name)
        guard let url = URL(string: "ws://\(leader.host):\(leader.httpPort)/ws/phone") else { return }
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive(on: task)
    }

    func connect(manualHost: String) {
        let host = manualHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        connect(to: DiscoveredLeader(name: host, host: host, httpPort: Int(SyncConstants.httpPort)))
    }

    func disconnect() {
        reconnectWork?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        status = .disconnected
    }

    func send(_ message: PhoneMessage) {
        guard let task, let data = try? encoder.encode(message) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case .success(let message):
                    if case .connected = self.status {} else { self.status = .connected(self.current?.name ?? "leader") }
                    if case .string(let text) = message,
                       let envelope = try? JSONDecoder().decode(StateEnvelope.self, from: Data(text.utf8)) {
                        self.state = envelope.state
                    }
                    self.receive(on: task)
                case .failure:
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard let leader = current else { return }
        status = .connecting(leader.name)
        reconnectWork?.cancel()
        reconnectWork = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.connect(to: leader)
        }
    }

    private struct StateEnvelope: Decodable {
        var state: UIState
    }
}
