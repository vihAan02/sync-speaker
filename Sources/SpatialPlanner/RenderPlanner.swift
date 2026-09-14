import Foundation

/// Horizontal-plane vector in ARKit world coordinates (x right, z toward the viewer at session start).
public struct Vec2: Equatable, Sendable {
    public var x: Double
    public var z: Double

    public init(_ x: Double, _ z: Double) {
        self.x = x
        self.z = z
    }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.z + b.z) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.z - b.z) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.z * s) }
    public func dot(_ o: Vec2) -> Double { x * o.x + z * o.z }
    public var length: Double { (x * x + z * z).squareRoot() }
    public var normalized: Vec2? { length > 1e-9 ? self * (1 / length) : nil }
    /// Right-hand vector for a Y-up world: forward (0,-1) → right (1,0).
    public var right: Vec2 { Vec2(-z, x) }
}

public enum ChannelAssignment: Equatable, Sendable {
    /// `leftSpeaker` receives the left channel, the other the right channel.
    case stereo(leftSpeaker: Int)
    case mono
}

public struct SpeakerPlan: Equatable, Sendable {
    public var delaySeconds: Double
    public var gain: Double
    /// 0 = left channel, 1 = right channel, nil = mono mix.
    public var channel: Int?
}

public struct RenderPlan: Equatable, Sendable {
    public var speakers: [SpeakerPlan]
    public var assignment: ChannelAssignment
    public var head: Vec2?
    public var facing: Vec2?
}

/// Sweet-spot-follow planner for a pair of speakers.
///
/// Delays the nearer speaker and attenuates the nearer one (1/r) so both wavefronts reach the listener's
/// head together at equal level, and routes left/right by which speaker is on the listener's left.
public struct RenderPlanner: Sendable {
    public struct Config: Sendable {
        public var speedOfSound = 343.0
        /// The phone is held this far in front of the face when not locked.
        public var handHeldOffset = 0.35
        public var minGain = 0.5 // -6 dB
        /// Lateral separation (difference of sin(azimuth)) below which both speakers play mono.
        public var monoEnter = 0.20
        public var monoExit = 0.30

        public init() {}
    }

    public var config: Config
    public private(set) var assignment: ChannelAssignment = .stereo(leftSpeaker: 0)
    private var filter = OneEuroFilter2D()

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func resetSmoothing() {
        filter.reset()
    }

    /// - Parameters:
    ///   - speakers: exactly two speaker positions; index 0 is the default left speaker.
    ///   - phone: raw phone position, or nil if the listener is unknown.
    ///   - forward: phone's horizontal facing vector, or nil to assume facing the speakers' midpoint.
    ///   - locked: the phone is resting at the listening spot rather than held in front of the face.
    ///   - time: seconds, monotonic, for smoothing.
    public mutating func plan(speakers: [Vec2], phone: Vec2?, forward: Vec2?, locked: Bool, time: Double) -> RenderPlan {
        precondition(speakers.count == 2, "v1 planner supports two speakers")
        guard let phone else {
            return RenderPlan(speakers: Self.neutral(assignment: assignment), assignment: assignment, head: nil, facing: nil)
        }

        let smoothed = filter.filter(phone, time: time)
        let facingIn = forward?.normalized
        var head = smoothed
        if !locked, let f = facingIn {
            // The user stands behind the phone they are holding.
            head = smoothed - f * config.handHeldOffset
        }
        let midpoint = (speakers[0] + speakers[1]) * 0.5
        let facing = facingIn ?? (midpoint - head).normalized ?? Vec2(0, -1)

        let vectors = speakers.map { $0 - head }
        let distances = vectors.map { max($0.length, 0.05) }
        let far = distances.max()!

        let plans = distances.map { r in
            SpeakerPlan(
                delaySeconds: (far - r) / config.speedOfSound,
                gain: max(config.minGain, r / far),
                channel: nil
            )
        }

        assignment = nextAssignment(vectors: vectors, distances: distances, facing: facing)
        var withChannels = plans
        if case .stereo(let left) = assignment {
            withChannels[left].channel = 0
            withChannels[1 - left].channel = 1
        }
        return RenderPlan(speakers: withChannels, assignment: assignment, head: head, facing: facing)
    }

    private func nextAssignment(vectors: [Vec2], distances: [Double], facing: Vec2) -> ChannelAssignment {
        let right = facing.right
        // sin(azimuth): +1 hard right, -1 hard left, 0 straight ahead or behind.
        let lateral = zip(vectors, distances).map { $0.dot(right) / $1 }
        let separation = lateral[1] - lateral[0] // > 0 when speaker 1 is right of speaker 0
        switch assignment {
        case .mono:
            guard abs(separation) > config.monoExit else { return .mono }
        case .stereo(let left):
            if abs(separation) < config.monoEnter { return .mono }
            // Keep the current routing unless the other speaker is clearly on the left.
            let currentLeftIsLeft = left == 0 ? separation > 0 : separation < 0
            if currentLeftIsLeft { return assignment }
        }
        return .stereo(leftSpeaker: separation > 0 ? 0 : 1)
    }

    static func neutral(assignment: ChannelAssignment) -> [SpeakerPlan] {
        var plans = [SpeakerPlan](repeating: SpeakerPlan(delaySeconds: 0, gain: 1, channel: nil), count: 2)
        if case .stereo(let left) = assignment {
            plans[left].channel = 0
            plans[1 - left].channel = 1
        }
        return plans
    }
}
