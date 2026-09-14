import ARKit
import Foundation
import Observation
import simd
import SyncProtocol

/// ARKit world tracking: places the speakers by touching the phone to each MacBook, then streams the
/// listener's position and facing direction to the leader.
@MainActor
@Observable
final class RoomTracker: NSObject {
    enum Tracking: Equatable {
        case notStarted, normal, limited(String), notAvailable
    }

    let session = ARSession()
    private(set) var tracking: Tracking = .notStarted
    private(set) var position = SIMD3<Float>(0, 0, 0)
    /// Horizontal facing vector (x, z), unit length.
    private(set) var forward = SIMD2<Float>(0, -1)
    private(set) var anchors: [SpeakerID: SIMD3<Float>] = [:]
    private(set) var locked = false
    private(set) var interrupted = false

    /// Called at ~30 Hz with the latest pose while running.
    @ObservationIgnored var onPose: (@MainActor (ListenerPose) -> Void)?
    @ObservationIgnored private var lastSent: TimeInterval = 0

    override init() {
        super.init()
        session.delegate = self
    }

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        session.run(config)
    }

    func pause() {
        session.pause()
    }

    /// Records the phone's current position as a speaker location.
    func placeSpeaker(_ speaker: SpeakerID) -> SpeakerAnchor {
        anchors[speaker] = position
        return SpeakerAnchor(speaker: speaker, position: [Double(position.x), Double(position.y), Double(position.z)])
    }

    func setLocked(_ value: Bool) {
        locked = value
    }

    /// Clears placed speakers and restarts world tracking from scratch.
    func resetRoom() {
        anchors = [:]
        locked = false
        interrupted = false
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    var anchorSpacing: Float? {
        guard let a = anchors[.a], let b = anchors[.b] else { return nil }
        return simd_distance(SIMD2(a.x, a.z), SIMD2(b.x, b.z))
    }

    func distance(to speaker: SpeakerID) -> Float? {
        anchors[speaker].map { simd_distance(SIMD2($0.x, $0.z), SIMD2(position.x, position.z)) }
    }

    fileprivate func update(transform: simd_float4x4, tracking: Tracking, timestamp: TimeInterval) {
        self.tracking = tracking
        let column = transform.columns.3
        position = SIMD3(column.x, column.y, column.z)
        // The back camera looks along its -Z axis, the direction the user faces while holding the phone.
        let back = transform.columns.2
        let horizontal = SIMD2(-back.x, -back.z)
        if simd_length(horizontal) > 0.2 { forward = simd_normalize(horizontal) }

        guard timestamp - lastSent >= 1.0 / 30, !locked else { return }
        lastSent = timestamp
        let state: ListenerPose.Tracking
        switch tracking {
        case .normal: state = .normal
        case .limited: state = .limited
        case .notAvailable, .notStarted: state = .notAvailable
        }
        onPose?(ListenerPose(
            position: [Double(position.x), Double(position.y), Double(position.z)],
            forward: [Double(forward.x), Double(forward.y)],
            tracking: state))
    }

    fileprivate func setInterrupted(_ value: Bool) {
        interrupted = value
    }
}

extension RoomTracker: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let transform = frame.camera.transform
        let timestamp = frame.timestamp
        let tracking = Self.tracking(from: frame.camera.trackingState)
        // ARSession delivers delegate callbacks on the main queue by default.
        MainActor.assumeIsolated {
            self.update(transform: transform, tracking: tracking, timestamp: timestamp)
        }
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

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated { self.setInterrupted(true) }
    }

    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        true
    }
}
