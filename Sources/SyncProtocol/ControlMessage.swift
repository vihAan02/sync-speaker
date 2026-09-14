import Foundation

/// JSON messages on the leader↔follower link.
public enum ControlMessage: Codable, Equatable, Sendable {
    case hello(NodeHello)
    case status(NodeStatus)
    case renderPlan(SpeakerRender)
    case settings(NodeSettings)
    case calibrate(CalibrationCommand)
    case calibrationResult(CalibrationReport)
}

public struct NodeHello: Codable, Equatable, Sendable {
    public var nodeID: String
    public var name: String
    public var role: NodeRole
    public var version: Int

    public init(nodeID: String, name: String, role: NodeRole, version: Int = 1) {
        self.nodeID = nodeID
        self.name = name
        self.role = role
        self.version = version
    }
}

public struct ClockStats: Codable, Equatable, Sendable {
    public var offsetMs: Double
    public var jitterMs: Double
    public var rttMs: Double
    public var skewPpm: Double
    public var samples: Int

    public init(offsetMs: Double = 0, jitterMs: Double = 0, rttMs: Double = 0, skewPpm: Double = 0, samples: Int = 0) {
        self.offsetMs = offsetMs
        self.jitterMs = jitterMs
        self.rttMs = rttMs
        self.skewPpm = skewPpm
        self.samples = samples
    }
}

public struct PlayoutStats: Codable, Equatable, Sendable {
    public var locked: Bool
    public var errorMs: Double
    public var ratioPpm: Double
    public var bufferMs: Double
    public var delayMs: Double
    public var gain: Double
    public var mixL: Double
    public var mixR: Double
    public var peakDb: Double
    public var underruns: Int
    public var resyncs: Int
    public var outputLatencyMs: Double
    public var trimMs: Double

    public init(locked: Bool = false, errorMs: Double = 0, ratioPpm: Double = 0, bufferMs: Double = 0,
                delayMs: Double = 0, gain: Double = 1, mixL: Double = 0.5, mixR: Double = 0.5,
                peakDb: Double = -120, underruns: Int = 0, resyncs: Int = 0, outputLatencyMs: Double = 0,
                trimMs: Double = 0) {
        self.locked = locked
        self.errorMs = errorMs
        self.ratioPpm = ratioPpm
        self.bufferMs = bufferMs
        self.delayMs = delayMs
        self.gain = gain
        self.mixL = mixL
        self.mixR = mixR
        self.peakDb = peakDb
        self.underruns = underruns
        self.resyncs = resyncs
        self.outputLatencyMs = outputLatencyMs
        self.trimMs = trimMs
    }
}

public struct NodeStatus: Codable, Equatable, Sendable {
    public var nodeID: String
    public var name: String
    public var role: NodeRole
    public var clock: ClockStats
    public var playout: PlayoutStats

    public init(nodeID: String, name: String, role: NodeRole, clock: ClockStats, playout: PlayoutStats) {
        self.nodeID = nodeID
        self.name = name
        self.role = role
        self.clock = clock
        self.playout = playout
    }
}

/// Per-speaker render targets computed by the leader's planner.
public struct SpeakerRender: Codable, Equatable, Sendable {
    public enum Channel: String, Codable, Sendable { case left = "L", right = "R", mono }

    public var delaySeconds: Double
    public var gain: Double
    public var channel: Channel

    public init(delaySeconds: Double = 0, gain: Double = 1, channel: Channel = .mono) {
        self.delaySeconds = delaySeconds
        self.gain = gain
        self.channel = channel
    }

    public var mix: (left: Float, right: Float) {
        switch channel {
        case .left: (1, 0)
        case .right: (0, 1)
        case .mono: (0.5, 0.5)
        }
    }
}

public struct NodeSettings: Codable, Equatable, Sendable {
    public var masterVolume: Double
    /// Extra real-world output latency of the receiving node, measured by acoustic calibration.
    public var trimSeconds: Double

    public init(masterVolume: Double = 1, trimSeconds: Double = 0) {
        self.masterVolume = masterVolume
        self.trimSeconds = trimSeconds
    }
}

/// Both nodes record `[recordStartClusterNs, +recordSeconds]` and play their chirp at `chirpStartClusterNs`.
public struct CalibrationCommand: Codable, Equatable, Sendable {
    public var id: UInt64
    public var recordStartClusterNs: Int64
    public var recordSeconds: Double
    /// Chirp start per speaker, in cluster time.
    public var chirpStartClusterNs: [SpeakerID: Int64]

    public init(id: UInt64, recordStartClusterNs: Int64, recordSeconds: Double, chirpStartClusterNs: [SpeakerID: Int64]) {
        self.id = id
        self.recordStartClusterNs = recordStartClusterNs
        self.recordSeconds = recordSeconds
        self.chirpStartClusterNs = chirpStartClusterNs
    }
}

/// Arrival times of each speaker's chirp inside one node's own recording (seconds from recording start).
public struct CalibrationReport: Codable, Equatable, Sendable {
    public var id: UInt64
    public var speaker: SpeakerID
    public var arrivals: [SpeakerID: Double]
    public var error: String?

    public init(id: UInt64, speaker: SpeakerID, arrivals: [SpeakerID: Double], error: String? = nil) {
        self.id = id
        self.speaker = speaker
        self.arrivals = arrivals
        self.error = error
    }
}
