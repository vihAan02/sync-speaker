import Foundation

/// Snapshot pushed to web and phone clients over `/ws/ui`.
public struct UIState: Codable, Equatable, Sendable {
    public struct Node: Codable, Equatable, Sendable {
        public var speaker: SpeakerID
        public var name: String
        public var role: NodeRole
        public var connected: Bool
        public var clock: ClockStats
        public var playout: PlayoutStats
        public var target: SpeakerRender

        public init(speaker: SpeakerID, name: String, role: NodeRole, connected: Bool, clock: ClockStats,
                    playout: PlayoutStats, target: SpeakerRender) {
            self.speaker = speaker
            self.name = name
            self.role = role
            self.connected = connected
            self.clock = clock
            self.playout = playout
            self.target = target
        }
    }

    public struct Point: Codable, Equatable, Sendable {
        public var x: Double
        public var z: Double

        public init(x: Double, z: Double) {
            self.x = x
            self.z = z
        }
    }

    public struct Room: Codable, Equatable, Sendable {
        public var speakers: [SpeakerID: Point]
        public var listener: Point?
        public var head: Point?
        public var forward: Point?
        public var locked: Bool
        public var tracking: String
        public var poseAgeMs: Double?
        public var anchored: Bool

        public init(speakers: [SpeakerID: Point] = [:], listener: Point? = nil, head: Point? = nil,
                    forward: Point? = nil, locked: Bool = false, tracking: String = "none",
                    poseAgeMs: Double? = nil, anchored: Bool = false) {
            self.speakers = speakers
            self.listener = listener
            self.head = head
            self.forward = forward
            self.locked = locked
            self.tracking = tracking
            self.poseAgeMs = poseAgeMs
            self.anchored = anchored
        }
    }

    public struct Music: Codable, Equatable, Sendable {
        public var running: Bool
        public var state: String
        public var name: String?
        public var artist: String?
        public var album: String?
        public var duration: Double?
        public var position: Double?
        public var volume: Int?

        public init(running: Bool = false, state: String = "stopped", name: String? = nil, artist: String? = nil,
                    album: String? = nil, duration: Double? = nil, position: Double? = nil, volume: Int? = nil) {
            self.running = running
            self.state = state
            self.name = name
            self.artist = artist
            self.album = album
            self.duration = duration
            self.position = position
            self.volume = volume
        }
    }

    public struct Capture: Codable, Equatable, Sendable {
        public var active: Bool
        public var sampleRate: Double
        public var levelDb: Double
        public var dropped: Int
        public var error: String?

        public init(active: Bool = false, sampleRate: Double = 0, levelDb: Double = -120, dropped: Int = 0,
                    error: String? = nil) {
            self.active = active
            self.sampleRate = sampleRate
            self.levelDb = levelDb
            self.dropped = dropped
            self.error = error
        }
    }

    public struct Calibration: Codable, Equatable, Sendable {
        public var status: String
        public var message: String?
        public var baselineMeters: Double?
        public var residualMs: Double?

        public init(status: String = "idle", message: String? = nil, baselineMeters: Double? = nil,
                    residualMs: Double? = nil) {
            self.status = status
            self.message = message
            self.baselineMeters = baselineMeters
            self.residualMs = residualMs
        }
    }

    public var leaderName: String
    public var nodes: [Node]
    public var room: Room
    public var spatialMode: SpatialMode
    public var playoutLatencyMs: Double
    public var masterVolume: Double
    public var music: Music
    public var capture: Capture
    public var calibration: Calibration

    public init(leaderName: String, nodes: [Node], room: Room, spatialMode: SpatialMode, playoutLatencyMs: Double,
                masterVolume: Double, music: Music, capture: Capture, calibration: Calibration) {
        self.leaderName = leaderName
        self.nodes = nodes
        self.room = room
        self.spatialMode = spatialMode
        self.playoutLatencyMs = playoutLatencyMs
        self.masterVolume = masterVolume
        self.music = music
        self.capture = capture
        self.calibration = calibration
    }
}

public enum SpatialMode: String, Codable, Sendable, CaseIterable {
    case off
    case sweetSpot
}

/// Commands from web/phone clients over `/ws/ui`.
public struct UICommand: Codable, Sendable {
    public var cmd: String
    public var action: String?
    public var value: Double?
    public var text: String?

    public init(cmd: String, action: String? = nil, value: Double? = nil, text: String? = nil) {
        self.cmd = cmd
        self.action = action
        self.value = value
        self.text = text
    }
}

public struct LibraryTrack: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var artist: String
    public var album: String

    public init(id: String, name: String, artist: String, album: String) {
        self.id = id
        self.name = name
        self.artist = artist
        self.album = album
    }
}

/// Non-state replies sent to a single `/ws/ui` client.
public enum UIReply: Codable, Sendable {
    case playlists([String])
    case searchResults(query: String, tracks: [LibraryTrack])
    case error(String)
}
