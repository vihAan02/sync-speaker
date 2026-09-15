import Foundation

/// iOS companion → leader over `ws://<leader>:8080/ws/phone`.
/// Positions are ARKit world coordinates in meters (Y up); `forward` is the horizontal facing vector (x, z).
public enum PhoneMessage: Codable, Equatable, Sendable {
    case anchor(SpeakerAnchor)
    case pose(ListenerPose)
    case lock(Bool)
    case resetRoom
    /// Lets the listener A/B the effect while walking around.
    case spatialMode(SpatialMode)
}

public struct SpeakerAnchor: Codable, Equatable, Sendable {
    public var speaker: SpeakerID
    public var position: [Double]

    public init(speaker: SpeakerID, position: [Double]) {
        self.speaker = speaker
        self.position = position
    }
}

public struct ListenerPose: Codable, Equatable, Sendable {
    public enum Tracking: String, Codable, Sendable { case normal, limited, notAvailable }

    public var position: [Double]
    public var forward: [Double]?
    public var tracking: Tracking

    public init(position: [Double], forward: [Double]?, tracking: Tracking) {
        self.position = position
        self.forward = forward
        self.tracking = tracking
    }
}
