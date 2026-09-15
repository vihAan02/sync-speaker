import ARKit
import Foundation
import Observation
import simd
import SyncProtocol

/// ARKit world tracking in three steps: scan the room into a map, place the MacBooks by tapping them in the camera
/// view, then stream the listener's position and facing direction to the leader while they walk around.
@MainActor
@Observable
final class RoomTracker: NSObject {
    enum Tracking: Equatable {
        case notStarted, normal, limited(String), notAvailable
    }

    enum Phase: Equatable {
        /// A saved room exists; waiting for the user to resume it or scan again.
        case choose
        /// Restoring a saved room. Poses are held back until ARKit recognizes the space.
        case relocalizing
        case scanning
        case placing
        case listening
    }

    /// Mirrors `ARFrame.WorldMappingStatus`: how much of the visible space ARKit has mapped.
    enum Mapping: Int, Comparable {
        case notAvailable, limited, extending, mapped

        static func < (a: Mapping, b: Mapping) -> Bool { a.rawValue < b.rawValue }
    }

    nonisolated static let isSupported = ARWorldTrackingConfiguration.isSupported
    /// LiDAR devices reconstruct a full room mesh; the rest detect flat planes.
    nonisolated static let supportsMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    let session = ARSession()
    private(set) var phase: Phase = .scanning
    private(set) var tracking: Tracking = .notStarted
    private(set) var mapping: Mapping = .notAvailable
    /// Square meters of reconstructed surface: mesh on LiDAR devices, detected planes otherwise.
    private(set) var surfaceArea: Float = 0
    private(set) var position = SIMD3<Float>(0, 0, 0)
    /// Horizontal facing vector (x, z), unit length.
    private(set) var forward = SIMD2<Float>(0, -1)
    private(set) var anchors: [SpeakerID: SIMD3<Float>] = [:]
    private(set) var locked = false
    private(set) var interrupted = false
    private(set) var hasSavedRoom = FileManager.default.fileExists(atPath: RoomTracker.roomURL.path)
    /// One-line result of the last save or restore, shown under the controls.
    private(set) var roomNotice: String?
    private(set) var failure: String?

    /// Messages for the leader: poses at ~30 Hz, speaker anchors, resets and lock changes.
    @ObservationIgnored var onMessage: (@MainActor (PhoneMessage) -> Void)?
    @ObservationIgnored private var lastSent: TimeInterval = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var speakerAnchors: [SpeakerID: ARAnchor] = [:]
    @ObservationIgnored private var sentAnchors: [SpeakerID: SIMD3<Float>] = [:]
    @ObservationIgnored private var surfaceAreas: [UUID: Float] = [:]
    /// Relocalized before the saved speaker anchors came back; jump to listening once they do.
    @ObservationIgnored private var awaitingRestoredSpeakers = false

    override init() {
        super.init()
        session.delegate = self
    }

    var isReadyToPlace: Bool {
        tracking == .normal && (mapping >= .extending || surfaceArea >= 3)
    }

    var anchorSpacing: Float? {
        guard let a = anchors[.a], let b = anchors[.b] else { return nil }
        return simd_distance(SIMD2(a.x, a.z), SIMD2(b.x, b.z))
    }

    func distance(to speaker: SpeakerID) -> Float? {
        anchors[speaker].map { simd_distance(SIMD2($0.x, $0.z), SIMD2(position.x, position.z)) }
    }

    // MARK: Phases

    func start() {
        guard !started else { return }
        started = true
        guard Self.isSupported else {
            tracking = .notAvailable
            return
        }
        phase = hasSavedRoom ? .choose : .scanning
        session.run(Self.configuration())
    }

    func pause() {
        session.pause()
    }

    /// Forgets the speakers and maps the room from scratch.
    func scanNewRoom() {
        clearRoom()
        phase = .scanning
        session.run(Self.configuration(), options: [.resetTracking, .removeExistingAnchors])
        onMessage?(.resetRoom)
    }

    /// Reloads the saved map. ARKit restores the speaker anchors once the camera recognizes the room.
    func resumeSavedRoom() {
        do {
            let data = try Data(contentsOf: Self.roomURL)
            guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            clearRoom()
            phase = .relocalizing
            session.run(Self.configuration(worldMap: map), options: [.resetTracking, .removeExistingAnchors])
        } catch {
            try? FileManager.default.removeItem(at: Self.roomURL)
            hasSavedRoom = false
            scanNewRoom()
            roomNotice = "The saved room couldn't be opened. Scan it again."
        }
    }

    func finishScanning() {
        phase = .placing
    }

    /// Back to scanning without losing the map or the placed speakers.
    func scanMore() {
        phase = .scanning
    }

    func editSpeakers() {
        phase = .placing
    }

    func startListening() {
        guard anchors.count == SpeakerID.allCases.count else { return }
        phase = .listening
        onMessage?(.spatialMode(.sweetSpot))
        saveRoom()
    }

    // MARK: Speakers

    /// Drops a speaker marker at a point in the room, e.g. where the user tapped the MacBook on screen.
    func placeSpeaker(_ speaker: SpeakerID, at point: SIMD3<Float>) {
        // Turn the marker's screen toward the phone, the way the real MacBook faces the person placing it.
        var toPhone = SIMD2(position.x - point.x, position.z - point.z)
        if simd_length(toPhone) < 0.05 { toPhone = -forward }
        var transform = simd_float4x4(simd_quatf(angle: atan2(toPhone.x, toPhone.y), axis: [0, 1, 0]))
        transform.columns.3 = SIMD4(point, 1)

        awaitingRestoredSpeakers = false
        if let old = speakerAnchors[speaker] { session.remove(anchor: old) }
        let anchor = ARAnchor(name: Self.anchorName(for: speaker), transform: transform)
        speakerAnchors[speaker] = anchor
        anchors[speaker] = point
        session.add(anchor: anchor)
        sendAnchor(speaker, force: true)
        if phase == .listening { saveRoom() }
    }

    /// The original method: hold the phone against the MacBook and use the phone's own position.
    func placeSpeakerAtPhone(_ speaker: SpeakerID) {
        placeSpeaker(speaker, at: position)
    }

    func setLocked(_ value: Bool) {
        locked = value
        onMessage?(.lock(value))
    }

    /// Everything the leader needs after (re)connecting, since it may hold anchors from an older session.
    func leaderSync() -> [PhoneMessage] {
        guard phase != .choose, phase != .relocalizing, Self.isSupported else { return [] }
        sentAnchors = [:]
        var messages: [PhoneMessage] = [.resetRoom]
        for speaker in SpeakerID.allCases where anchors[speaker] != nil {
            messages.append(.anchor(anchorMessage(speaker)))
            sentAnchors[speaker] = anchors[speaker]
        }
        messages.append(.lock(locked))
        return messages
    }

    nonisolated static func anchorName(for speaker: SpeakerID) -> String {
        "syncspeaker.\(speaker.rawValue)"
    }

    nonisolated static func speaker(for anchor: ARAnchor) -> SpeakerID? {
        guard let name = anchor.name, name.hasPrefix("syncspeaker.") else { return nil }
        return SpeakerID(rawValue: String(name.dropFirst("syncspeaker.".count)))
    }

    private func anchorMessage(_ speaker: SpeakerID) -> SpeakerAnchor {
        let p = anchors[speaker] ?? .zero
        return SpeakerAnchor(speaker: speaker, position: [Double(p.x), Double(p.y), Double(p.z)])
    }

    /// Sends a speaker position when it is new or ARKit has refined it by more than 2 cm.
    private func sendAnchor(_ speaker: SpeakerID, force: Bool = false) {
        guard let p = anchors[speaker], phase != .choose, phase != .relocalizing else { return }
        if !force, let sent = sentAnchors[speaker], simd_distance(sent, p) < 0.02 { return }
        sentAnchors[speaker] = p
        onMessage?(.anchor(anchorMessage(speaker)))
    }

    private func clearRoom() {
        anchors = [:]
        speakerAnchors = [:]
        sentAnchors = [:]
        surfaceAreas = [:]
        surfaceArea = 0
        awaitingRestoredSpeakers = false
        mapping = .notAvailable
        locked = false
        interrupted = false
        roomNotice = nil
    }

    // MARK: Saved room

    private nonisolated static var roomURL: URL {
        URL.applicationSupportDirectory.appending(path: "room.arworldmap")
    }

    private nonisolated static func configuration(worldMap: ARWorldMap? = nil) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else if supportsMesh {
            config.sceneReconstruction = .mesh
        }
        config.initialWorldMap = worldMap
        return config
    }

    /// Archives the current map with its speaker anchors so the room can be restored without rescanning.
    private func saveRoom() {
        session.getCurrentWorldMap { map, error in
            var problem: String?
            if let map {
                do {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                    try FileManager.default.createDirectory(at: URL.applicationSupportDirectory,
                                                            withIntermediateDirectories: true)
                    try data.write(to: Self.roomURL, options: .atomic)
                } catch {
                    problem = error.localizedDescription
                }
            } else {
                problem = "look around the MacBooks a bit more"
            }
            DispatchQueue.main.async {
                if let problem {
                    self.roomNotice = "Room not saved yet: \(problem)."
                } else {
                    self.hasSavedRoom = true
                    self.roomNotice = "Room saved. Next time you can restore it without scanning."
                }
            }
        }
    }

    // MARK: Session updates

    fileprivate func update(transform: simd_float4x4, tracking: Tracking, mapping: Mapping, timestamp: TimeInterval) {
        if self.tracking != tracking { self.tracking = tracking }
        if self.mapping != mapping { self.mapping = mapping }
        if tracking == .normal {
            if interrupted { interrupted = false }
            if phase == .relocalizing { didRelocalize() }
        }

        let column = transform.columns.3
        position = SIMD3(column.x, column.y, column.z)
        // The back camera looks along its -Z axis, the direction the user faces while holding the phone.
        let back = transform.columns.2
        let horizontal = SIMD2(-back.x, -back.z)
        if simd_length(horizontal) > 0.2 { forward = simd_normalize(horizontal) }

        // Poses only mean something to the planner once both speakers are in this session's coordinates.
        guard phase == .placing || phase == .listening, anchors.count == SpeakerID.allCases.count,
              timestamp - lastSent >= 1.0 / 30, !locked else { return }
        lastSent = timestamp
        let state: ListenerPose.Tracking
        switch tracking {
        case .normal: state = .normal
        case .limited: state = .limited
        case .notAvailable, .notStarted: state = .notAvailable
        }
        onMessage?(.pose(ListenerPose(
            position: [Double(position.x), Double(position.y), Double(position.z)],
            forward: [Double(forward.x), Double(forward.y)],
            tracking: state)))
    }

    private func didRelocalize() {
        let complete = anchors.count == SpeakerID.allCases.count
        phase = complete ? .listening : .placing
        awaitingRestoredSpeakers = !complete
        roomNotice = "Room restored."
        leaderSync().forEach { onMessage?($0) }
    }

    fileprivate func ingest(_ added: [ARAnchor]) {
        var areaChanged = false
        for anchor in added {
            if let speaker = Self.speaker(for: anchor) {
                // A replaced marker can still report once; only follow the current one.
                if let current = speakerAnchors[speaker], current.identifier != anchor.identifier { continue }
                speakerAnchors[speaker] = anchor
                let p = SIMD3(anchor.transform.columns.3.x, anchor.transform.columns.3.y, anchor.transform.columns.3.z)
                if anchors[speaker].map({ simd_distance($0, p) > 0.002 }) ?? true { anchors[speaker] = p }
                sendAnchor(speaker)
                if awaitingRestoredSpeakers, phase == .placing, anchors.count == SpeakerID.allCases.count {
                    awaitingRestoredSpeakers = false
                    phase = .listening
                }
            } else if let mesh = anchor as? ARMeshAnchor {
                surfaceAreas[anchor.identifier] = mesh.geometry.surfaceArea
                areaChanged = true
            } else if let plane = anchor as? ARPlaneAnchor, !Self.supportsMesh {
                surfaceAreas[anchor.identifier] = plane.planeExtent.width * plane.planeExtent.height
                areaChanged = true
            }
        }
        if areaChanged { surfaceArea = surfaceAreas.values.reduce(0, +) }
    }

    fileprivate func remove(_ removed: [ARAnchor]) {
        for anchor in removed {
            if let speaker = Self.speaker(for: anchor), speakerAnchors[speaker]?.identifier == anchor.identifier {
                speakerAnchors[speaker] = nil
                anchors[speaker] = nil
            }
            surfaceAreas[anchor.identifier] = nil
        }
        surfaceArea = surfaceAreas.values.reduce(0, +)
    }

    fileprivate func setInterrupted(_ value: Bool) {
        interrupted = value
    }

    fileprivate func fail(_ error: Error) {
        failure = (error as? ARError)?.code == .cameraUnauthorized
            ? "Camera access is off. Turn it on in Settings › SyncSpeaker to map the room."
            : error.localizedDescription
    }
}

extension RoomTracker: ARSessionDelegate {
    // ARSession delivers delegate callbacks on the main queue by default.

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let transform = frame.camera.transform
        let timestamp = frame.timestamp
        let tracking = Self.tracking(from: frame.camera.trackingState)
        let mapping: Mapping = switch frame.worldMappingStatus {
        case .limited: .limited
        case .extending: .extending
        case .mapped: .mapped
        default: .notAvailable
        }
        MainActor.assumeIsolated {
            self.update(transform: transform, tracking: tracking, mapping: mapping, timestamp: timestamp)
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        MainActor.assumeIsolated { self.ingest(anchors) }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        MainActor.assumeIsolated { self.ingest(anchors) }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        MainActor.assumeIsolated { self.remove(anchors) }
    }

    nonisolated static func tracking(from state: ARCamera.TrackingState) -> Tracking {
        switch state {
        case .normal:
            return .normal
        case .notAvailable:
            return .notAvailable
        case .limited(let reason):
            let text: String
            switch reason {
            case .initializing: text = "initializing"
            case .excessiveMotion: text = "moving too fast"
            case .insufficientFeatures: text = "point at a textured surface"
            case .relocalizing: text = "relocalizing"
            @unknown default: text = "limited"
            }
            return .limited(text)
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        MainActor.assumeIsolated { self.fail(error) }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated { self.setInterrupted(true) }
    }

    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        true
    }
}

extension ARMeshGeometry {
    /// Total triangle area in square meters.
    var surfaceArea: Float {
        guard vertices.format == .float3, faces.bytesPerIndex == MemoryLayout<UInt32>.size,
              faces.indexCountPerPrimitive == 3 else { return 0 }
        let vertexBase = vertices.buffer.contents().advanced(by: vertices.offset)
        let stride = vertices.stride
        let indices = faces.buffer.contents()
        func vertex(_ face: Int, _ corner: Int) -> SIMD3<Float> {
            let index = Int(indices.loadUnaligned(fromByteOffset: (face * 3 + corner) * 4, as: UInt32.self))
            let v = vertexBase.loadUnaligned(fromByteOffset: index * stride, as: (Float, Float, Float).self)
            return SIMD3(v.0, v.1, v.2)
        }
        var area: Float = 0
        for face in 0..<faces.count {
            let a = vertex(face, 0)
            area += simd_length(simd_cross(vertex(face, 1) - a, vertex(face, 2) - a))
        }
        return area / 2
    }
}
