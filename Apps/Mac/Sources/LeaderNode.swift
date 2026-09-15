import Calibration
import ClockSync
import ControlServer
import Foundation
import MusicControl
import SpatialPlanner
import SyncProtocol
import Transport

/// Speaker A: captures audio, owns the cluster clock, serves the web UI, plans spatial rendering.
final class LeaderNode: @unchecked Sendable {
    let audio = NodeAudio()
    let settings: SettingsStore
    let name = HostNames.computerName
    private let link = LinkServer()
    private let clock = ClockServer()
    private let music: MusicController
    private let webRoot: String
    private var source: LeaderSource!

    private let lock = NSLock()
    private var planner = RenderPlanner()
    private var anchors: [SpeakerID: [Double]]
    private var pose: ListenerPose?
    private var locked = false
    private var poseReceivedNs: Int64 = 0
    private var phoneConnected = false
    private var lastPlan: RenderPlan?
    private var targets: [SpeakerID: SpeakerRender] = [.a: SpeakerRender(channel: .left), .b: SpeakerRender(channel: .right)]
    private var follower: (peer: UUID, status: NodeStatus?)?
    private var calibration = UIState.Calibration()
    private var pendingReports: [UInt64: CheckedContinuation<CalibrationReport?, Never>] = [:]
    private var musicState = UIState.Music()
    private var calibrating = false

    private var timers: [DispatchSourceTimer] = []
    private var serverTask: Task<Void, Never>?
    private var musicTask: Task<Void, Never>?
    private(set) var serverError: String?

    init(settings: SettingsStore, music: MusicController, webRoot: String, sourceKind: LeaderSource.Kind) {
        self.settings = settings
        self.music = music
        self.webRoot = webRoot
        anchors = settings.anchors
        source = LeaderSource(kind: sourceKind, engine: audio.engine, link: link) { [settings] in
            Int64(settings.playoutLatencyMs * 1e6)
        }
    }

    func start() throws {
        // The leader's host clock *is* cluster time.
        audio.engine.setClockMap(localRefNs: 0, clusterRefNs: 0, rate: 1)
        audio.engine.setMaster(settings.masterVolume)
        audio.engine.trim = 0
        try audio.start() // start output first so our process is excluded from the tap
        try clock.start()
        link.onControl = { [weak self] peer, message in self?.handleLink(peer: peer, message: message) }
        link.onPeersChanged = { [weak self] in self?.refreshFollower() }
        try link.start(serviceName: name, httpPort: SyncConstants.httpPort, hostName: HostNames.localHostName)
        do {
            try source.start()
        } catch {
            // Keep serving the UI so the problem is visible there.
            NSLog("SyncSpeaker: capture failed: \(error)")
        }

        let server = ControlServer(webRoot: webRoot, delegate: LeaderAPI(node: self))
        serverTask = Task.detached { [weak self] in
            do {
                try await server.run()
            } catch {
                self?.lock.withLock { self?.serverError = "\(error)" }
                NSLog("SyncSpeaker: web server stopped: \(error)")
            }
        }
        musicTask = Task { @MainActor [weak self, music] in
            while !Task.isCancelled {
                let state = music.status()
                self?.lock.withLock { self?.musicState = state }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        timers.append(repeating(every: 0.05) { [weak self] in self?.planTick() })
        timers.append(repeating(every: 2) { [weak self] in self?.audio.restartIfDeviceChanged() })
    }

    func stop() {
        timers.forEach { $0.cancel() }
        timers.removeAll()
        serverTask?.cancel()
        musicTask?.cancel()
        source.stop()
        link.stop()
        clock.stop()
        audio.stop()
        lock.withLock {
            pendingReports.values.forEach { $0.resume(returning: nil) }
            pendingReports.removeAll()
        }
    }

    // MARK: Spatial planning

    private func planTick() {
        let now = Double(HostClock.nowNs()) / 1e9
        let (plan, mode) = lock.withLock { () -> (RenderPlan, SpatialMode) in
            let speakers = speakerPositions()
            let mode = settings.spatialMode
            let phone = mode == .sweetSpot ? pose.map { Vec2($0.position[0], $0.position[2]) } : nil
            let forward = pose?.forward.flatMap { $0.count == 2 ? Vec2($0[0], $0[1]) : nil }
            let plan = planner.plan(speakers: [speakers[.a]!, speakers[.b]!], phone: phone, forward: forward,
                                    locked: locked, time: now)
            lastPlan = plan
            return (plan, mode)
        }
        var renders: [SpeakerID: SpeakerRender] = [:]
        for (index, speaker) in [SpeakerID.a, .b].enumerated() {
            let p = plan.speakers[index]
            let channel: SpeakerRender.Channel = switch p.channel {
            case 0: .left
            case 1: .right
            default: .mono
            }
            renders[speaker] = mode == .off
                ? SpeakerRender(delaySeconds: 0, gain: 1, channel: speaker == .a ? .left : .right)
                : SpeakerRender(delaySeconds: p.delaySeconds, gain: p.gain, channel: channel)
        }
        let followerPeer = lock.withLock { () -> UUID? in
            targets = renders
            return follower?.peer
        }
        audio.engine.setRender(renders[.a]!)
        if let followerPeer {
            link.send(.renderPlan(renders[.b]!), to: followerPeer)
            link.send(.settings(followerSettings()), to: followerPeer)
        }
    }

    private func followerSettings() -> NodeSettings {
        NodeSettings(masterVolume: calibrating ? 0 : settings.masterVolume, trimSeconds: settings.followerTrimSeconds)
    }

    /// Speaker positions in the horizontal plane: ARKit anchors when set, otherwise a line along x.
    private func speakerPositions() -> [SpeakerID: Vec2] {
        if let a = anchors[.a], let b = anchors[.b], a.count == 3, b.count == 3 {
            return [.a: Vec2(a[0], a[2]), .b: Vec2(b[0], b[2])]
        }
        let half = (settings.baselineMeters ?? 1.5) / 2
        return [.a: Vec2(-half, 0), .b: Vec2(half, 0)]
    }

    // MARK: Link

    private func refreshFollower() {
        let followers = link.connectedPeers.filter { $0.hello?.role == .follower }
        lock.withLock {
            if let first = followers.first {
                if follower?.peer != first.connection.id { follower = (first.connection.id, nil) }
            } else {
                follower = nil
            }
        }
    }

    private func handleLink(peer: UUID, message: ControlMessage) {
        switch message {
        case .status(let status):
            lock.withLock { if follower?.peer == peer { follower?.status = status } }
        case .calibrationResult(let report):
            lock.withLock { pendingReports.removeValue(forKey: report.id) }?.resume(returning: report)
        default:
            break
        }
    }

    // MARK: Calibration

    func calibrateSync() async {
        let (peer, busy) = lock.withLock { (follower?.peer, calibrating) }
        guard !busy else { return }
        guard let peer else {
            lock.withLock { calibration = .init(status: "failed", message: "No follower connected") }
            return
        }
        lock.withLock {
            calibrating = true
            calibration = .init(status: "running", message: "Listening for chirps…")
        }
        let savedMaster = settings.masterVolume
        audio.engine.setMaster(0) // duck music on both nodes
        defer {
            audio.engine.setMaster(savedMaster)
            lock.withLock { calibrating = false }
        }
        try? await Task.sleep(for: .milliseconds(200))

        let id = UInt64.random(in: 1...UInt64.max)
        let command = CalibrationProcedure.command(id: id, nowClusterNs: HostClock.nowNs())
        async let remote: CalibrationReport? = withCheckedContinuation { continuation in
            lock.withLock { pendingReports[id] = continuation }
            link.send(.calibrate(command), to: peer)
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.lock.withLock { self?.pendingReports.removeValue(forKey: id) }?.resume(returning: nil)
            }
        }
        let local = await CalibrationProcedure.perform(command, as: .a, audio: audio) { $0 }
        let reportB = await remote

        guard let reportB else {
            lock.withLock { calibration = .init(status: "failed", message: "Follower did not report back") }
            return
        }
        if let error = local.error ?? reportB.error {
            lock.withLock { calibration = .init(status: "failed", message: error) }
            return
        }
        guard let aA = local.arrivals[.a], let aB = local.arrivals[.b],
              let bA = reportB.arrivals[.a], let bB = reportB.arrivals[.b] else { return }
        let result = TwoWaySolver.solve(xA: aB - aA, xB: bB - bA, staggerSeconds: CalibrationProcedure.staggerSeconds)
        guard result.distanceMeters < 30, abs(result.bLateBySeconds) < 0.2 else {
            lock.withLock {
                calibration = .init(status: "failed", message: String(
                    format: "Implausible result (%.2f m, %.1f ms) — try a quieter room", result.distanceMeters,
                    result.bLateBySeconds * 1000))
            }
            return
        }
        settings.followerTrimSeconds += result.bLateBySeconds
        settings.baselineMeters = result.distanceMeters
        lock.withLock {
            calibration = .init(status: "done", message: "Follower trim adjusted", baselineMeters: result.distanceMeters,
                                residualMs: result.bLateBySeconds * 1000)
        }
    }

    // MARK: State for clients

    func uiState() -> UIState {
        let localStatus = audio.engine.stats()
        let sourceStats = source.currentStats
        return lock.withLock {
            let speakers = speakerPositions()
            var nodes = [UIState.Node(
                speaker: .a, name: name, role: .leader, connected: true, clock: ClockStats(samples: 1),
                playout: localStatus, target: targets[.a]!)]
            if let follower {
                nodes.append(UIState.Node(
                    speaker: .b, name: follower.status?.name ?? "Follower", role: .follower, connected: true,
                    clock: follower.status?.clock ?? ClockStats(), playout: follower.status?.playout ?? PlayoutStats(),
                    target: targets[.b]!))
            }
            let point = { (v: Vec2) in UIState.Point(x: v.x, z: v.z) }
            let room = UIState.Room(
                speakers: speakers.mapValues(point),
                listener: pose.map { UIState.Point(x: $0.position[0], z: $0.position[2]) },
                head: lastPlan?.head.map(point),
                forward: lastPlan?.facing.map(point),
                locked: locked,
                tracking: phoneConnected ? (pose?.tracking.rawValue ?? "waiting") : "disconnected",
                poseAgeMs: pose == nil ? nil : Double(HostClock.nowNs() - poseReceivedNs) / 1e6,
                anchored: anchors[.a] != nil && anchors[.b] != nil)
            return UIState(
                leaderName: name, nodes: nodes, room: room, spatialMode: settings.spatialMode,
                playoutLatencyMs: settings.playoutLatencyMs, masterVolume: settings.masterVolume, music: musicState,
                capture: UIState.Capture(active: sourceStats.active, sampleRate: sourceStats.sampleRate,
                                         levelDb: sourceStats.levelDb, dropped: sourceStats.dropped,
                                         error: sourceStats.error ?? serverError),
                calibration: calibration)
        }
    }

    fileprivate func handle(command: UICommand) async -> UIReply? {
        do {
            switch command.cmd {
            case "music":
                guard let action = command.action else { return nil }
                if action == "volume", let value = command.value {
                    try await MainActor.run { try music.setVolume(Int(value)) }
                } else if let a = MusicController.Action(rawValue: action == "next" ? "next track" : action == "previous" ? "previous track" : action) {
                    try await MainActor.run { try music.perform(a) }
                }
            case "playlists":
                return .playlists(try await MainActor.run { try music.playlists() })
            case "playPlaylist":
                guard let name = command.text else { return nil }
                try await MainActor.run { try music.playPlaylist(named: name) }
            case "search":
                guard let query = command.text, !query.isEmpty else { return nil }
                return .searchResults(query: query, tracks: try await MainActor.run { try music.searchLibrary(query) })
            case "playTrack":
                guard let id = command.text else { return nil }
                try await MainActor.run { try music.playTrack(persistentID: id) }
            case "spatialMode":
                if let mode = command.text.flatMap(SpatialMode.init(rawValue:)) { settings.spatialMode = mode }
            case "playoutLatency":
                if let ms = command.value { settings.playoutLatencyMs = min(1_000, max(80, ms)) }
            case "masterVolume":
                if let v = command.value {
                    settings.masterVolume = min(1, max(0, v))
                    audio.engine.setMaster(settings.masterVolume)
                }
            case "calibrateSync":
                Task { await calibrateSync() }
            case "resetTrim":
                settings.followerTrimSeconds = 0
                lock.withLock { calibration = .init(status: "idle", message: "Trim reset") }
            default:
                return .error("Unknown command \(command.cmd)")
            }
        } catch {
            return .error("\(error)")
        }
        return nil
    }

    fileprivate func handle(phone: PhoneMessage) {
        lock.withLock {
            switch phone {
            case .anchor(let anchor):
                anchors[anchor.speaker] = anchor.position
                settings.anchors = anchors
                planner.resetSmoothing()
            case .pose(let newPose):
                guard !locked, newPose.position.count == 3 else { return }
                pose = newPose
                poseReceivedNs = HostClock.nowNs()
            case .lock(let isLocked):
                locked = isLocked
            case .resetRoom:
                anchors = [:]
                settings.anchors = [:]
                pose = nil
                locked = false
                planner.resetSmoothing()
            case .spatialMode(let mode):
                settings.spatialMode = mode
            }
        }
    }

    fileprivate func setPhoneConnected(_ connected: Bool) {
        lock.withLock { phoneConnected = connected }
    }

    private func repeating(every seconds: Double, _ body: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(5))
        timer.setEventHandler(handler: body)
        timer.resume()
        return timer
    }
}

/// Bridges the HTTP/WebSocket server to the leader.
private struct LeaderAPI: ControlServerDelegate {
    let node: LeaderNode

    func currentState() async -> UIState { node.uiState() }
    func handle(command: UICommand) async -> UIReply? { await node.handle(command: command) }
    func handle(phone: PhoneMessage) async { node.handle(phone: phone) }
    func phoneConnectionChanged(connected: Bool) async { node.setPhoneConnected(connected) }
}
