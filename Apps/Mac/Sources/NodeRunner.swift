import Foundation
import MusicControl
import Observation
import SyncProtocol

/// Owns the active node and switches roles.
@MainActor
@Observable
final class NodeRunner {
    let settings: SettingsStore
    private let music: MusicController
    private(set) var role: NodeRole?
    private(set) var error: String?
    @ObservationIgnored private var leader: LeaderNode?
    @ObservationIgnored private var follower: FollowerNode?

    init(settings: SettingsStore, music: MusicController) {
        self.settings = settings
        self.music = music
    }

    func start(role: NodeRole, source: LeaderSource.Kind = .systemTap, leaderHost: String? = nil, webRoot: String) throws {
        stop()
        error = nil
        do {
            switch role {
            case .leader:
                let node = LeaderNode(settings: settings, music: music, webRoot: webRoot, sourceKind: source)
                try node.start()
                leader = node
            case .follower:
                let node = FollowerNode(leaderHost: leaderHost)
                try node.start()
                follower = node
            }
            self.role = role
        } catch {
            self.error = "\(error)"
            stop()
            throw error
        }
    }

    func stop() {
        leader?.stop()
        follower?.stop()
        leader = nil
        follower = nil
        role = nil
    }

    func calibrate() {
        guard let leader else { return }
        Task.detached { await leader.calibrateSync() }
    }

    /// Menu/terminal status lines.
    func statusLines() -> [String] {
        if let leader {
            let s = leader.audio.engine.stats()
            var lines = [String(format: "Output: %@ · buffer %.0f ms · peak %.0f dB", leader.audio.output.deviceName, s.bufferMs, s.peakDb)]
            do {
                let ui = leader.uiState()
                lines.append(ui.capture.active
                    ? String(format: "Capture: %.0f Hz · level %.0f dB", ui.capture.sampleRate, ui.capture.levelDb)
                    : "Capture: off\(ui.capture.error.map { " (\($0))" } ?? "")")
                if let b = ui.nodes.first(where: { $0.speaker == .b }) {
                    lines.append(String(format: "Follower %@: sync err %.2f ms · clock jitter %.2f ms · underruns %d",
                                        b.name, b.playout.errorMs, b.clock.jitterMs, b.playout.underruns))
                } else {
                    lines.append("Follower: not connected")
                }
                if let msg = ui.calibration.message { lines.append("Calibration: \(ui.calibration.status) — \(msg)") }
            }
            return lines
        }
        if let follower {
            let status = follower.status
            let link: String = switch follower.linkState {
            case .searching: "searching for leader…"
            case .connecting(let name): "connecting to \(name)…"
            case .connected(let name): "connected to \(name)"
            }
            return [
                "Link: \(link)",
                String(format: "Clock: offset %.3f ms · jitter %.3f ms · rtt %.1f ms · %.1f ppm",
                       status.clock.offsetMs, status.clock.jitterMs, status.clock.rttMs, status.clock.skewPpm),
                String(format: "Playout: %@ · err %.3f ms · %.0f ppm · buffer %.0f ms · underruns %d",
                       status.playout.locked ? "locked" : "waiting", status.playout.errorMs, status.playout.ratioPpm,
                       status.playout.bufferMs, status.playout.underruns),
            ]
        }
        return [error.map { "Error: \($0)" } ?? "Stopped"]
    }

    func summaryLine() -> String {
        statusLines().joined(separator: " | ")
    }
}
