import Foundation

public enum SyncConstants {
    /// Bonjour service advertised by the leader's link listener. TXT: role, http, host.
    public static let bonjourType = "_syncspeaker._tcp"
    public static let linkPort: UInt16 = 47810
    public static let clockPort: UInt16 = 47811
    public static let httpPort: UInt16 = 8080

    public static let defaultPlayoutLatencyMs = 300.0
    public static let speedOfSound = 343.0
}

public enum NodeRole: String, Codable, Sendable, CaseIterable {
    case leader
    case follower
}

/// v1 supports exactly two speakers: the leader is A, the follower is B.
public enum SpeakerID: String, Codable, CodingKeyRepresentable, Sendable, CaseIterable {
    case a = "A"
    case b = "B"

    public init(role: NodeRole) {
        self = role == .leader ? .a : .b
    }
}

public enum HostClock {
    /// Monotonic nanoseconds on the same timebase as Core Audio host time.
    @inlinable
    public static func nowNs() -> Int64 {
        Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    private static let timebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (info.numer, info.denom)
    }()

    /// Converts a mach/Core Audio host time to nanoseconds.
    public static func ns(fromHostTime hostTime: UInt64) -> Int64 {
        let tb = timebase
        if tb.numer == tb.denom { return Int64(hostTime) }
        return Int64((Double(hostTime) * Double(tb.numer) / Double(tb.denom)).rounded())
    }
}
