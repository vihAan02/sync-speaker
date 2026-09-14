import Foundation
import SyncProtocol

/// Persisted node configuration (UserDefaults).
final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func value<T>(_ key: String, _ fallback: T) -> T {
        lock.withLock { defaults.object(forKey: key) as? T ?? fallback }
    }

    private func set(_ key: String, _ value: Any?) {
        lock.withLock { defaults.set(value, forKey: key) }
    }

    var role: NodeRole? {
        get { value("role", String?.none).flatMap(NodeRole.init(rawValue:)) }
        set { set("role", newValue?.rawValue) }
    }

    var leaderHost: String? {
        get { value("leaderHost", String?.none) }
        set { set("leaderHost", newValue) }
    }

    var spatialMode: SpatialMode {
        get { SpatialMode(rawValue: value("spatialMode", SpatialMode.sweetSpot.rawValue)) ?? .sweetSpot }
        set { set("spatialMode", newValue.rawValue) }
    }

    var playoutLatencyMs: Double {
        get { value("playoutLatencyMs", SyncConstants.defaultPlayoutLatencyMs) }
        set { set("playoutLatencyMs", newValue) }
    }

    /// Session-only volume (e.g. `--volume 0` for silent test runs); never persisted.
    var masterVolumeOverride: Double?

    var masterVolume: Double {
        get { lock.withLock { masterVolumeOverride } ?? value("masterVolume", 1.0) }
        set {
            if lock.withLock({ masterVolumeOverride != nil }) {
                lock.withLock { masterVolumeOverride = newValue }
            } else {
                set("masterVolume", newValue)
            }
        }
    }

    /// Extra latency applied on the follower (speaker B), from acoustic calibration.
    var followerTrimSeconds: Double {
        get { value("followerTrimSeconds", 0.0) }
        set { set("followerTrimSeconds", newValue) }
    }

    var baselineMeters: Double? {
        get { value("baselineMeters", Double?.none) }
        set { set("baselineMeters", newValue) }
    }

    /// ARKit world positions of the speakers, keyed by SpeakerID raw value.
    var anchors: [SpeakerID: [Double]] {
        get {
            let raw: [String: [Double]] = value("anchors", [:])
            return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in SpeakerID(rawValue: k).map { ($0, v) } })
        }
        set { set("anchors", Dictionary(uniqueKeysWithValues: newValue.map { ($0.rawValue, $1) })) }
    }
}

enum HostNames {
    /// "Name.local" for Bonjour/HTTP links, and a friendly computer name for display.
    static var localHostName: String {
        let name = ProcessInfo.processInfo.hostName
        return name.hasSuffix(".local") ? name : name + ".local"
    }

    static var computerName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}
