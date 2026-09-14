import ClockSync
import Foundation
import SyncProtocol
import Transport

/// Speaker B: follows the leader's clock, plays the stream with the leader's render plan.
final class FollowerNode: @unchecked Sendable {
    let audio = NodeAudio()
    let name = HostNames.computerName
    private let nodeID = UUID().uuidString
    private let link: LinkClient
    private let clock = ClockClient()
    private let lock = NSLock()
    private var timers: [DispatchSourceTimer] = []
    private(set) var linkState: LinkClient.State = .searching
    private var clockStats = ClockEstimator.Stats()

    init(leaderHost: String?) {
        link = LinkClient(hello: NodeHello(nodeID: nodeID, name: HostNames.computerName, role: .follower),
                          fixedHost: leaderHost)
    }

    func start() throws {
        try audio.start()
        let engine = audio.engine

        clock.onUpdate = { [weak self] map, stats in
            engine.setClockMap(localRefNs: map.localRefNs, clusterRefNs: map.clusterRefNs, rate: map.rate)
            self?.lock.withLock { self?.clockStats = stats }
        }
        link.onLeaderHost = { [weak self] host in
            guard let self else { return }
            if let host { self.clock.start(host: host) } else { self.clock.stop() }
        }
        link.onStateChange = { [weak self] state in
            self?.lock.withLock { self?.linkState = state }
        }
        link.onAudio = { data in
            try? engine.ingest(chunk: data)
        }
        link.onControl = { [weak self] message in
            self?.handle(message)
        }
        link.start()

        timers.append(repeating(every: 0.5) { [weak self] in self?.sendStatus() })
        timers.append(repeating(every: 2) { [weak self] in self?.audio.restartIfDeviceChanged() })
    }

    func stop() {
        timers.forEach { $0.cancel() }
        timers.removeAll()
        link.stop()
        clock.stop()
        audio.stop()
    }

    var status: NodeStatus {
        let stats = lock.withLock { clockStats }
        return NodeStatus(
            nodeID: nodeID, name: name, role: .follower,
            clock: ClockStats(offsetMs: stats.offsetNs / 1e6, jitterMs: stats.jitterNs / 1e6,
                              rttMs: stats.roundTripNs / 1e6, skewPpm: stats.skewPpm, samples: stats.goodSamples),
            playout: audio.engine.stats())
    }

    private func sendStatus() {
        link.send(.status(status))
    }

    private func handle(_ message: ControlMessage) {
        switch message {
        case .renderPlan(let render):
            audio.engine.setRender(render)
        case .settings(let settings):
            audio.engine.setMaster(settings.masterVolume)
            if abs(audio.engine.trim - settings.trimSeconds) > 1e-7 { audio.engine.trim = settings.trimSeconds }
        case .calibrate(let command):
            Task { [weak self] in
                guard let self else { return }
                let map = self.clock.map
                let report = await CalibrationProcedure.perform(command, as: .b, audio: self.audio) { cluster in
                    map?.toLocal(cluster) ?? cluster
                }
                self.link.send(.calibrationResult(report))
            }
        default:
            break
        }
    }

    private func repeating(every seconds: Double, _ body: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(20))
        timer.setEventHandler(handler: body)
        timer.resume()
        return timer
    }
}
