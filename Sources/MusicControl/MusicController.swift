import Foundation
import SyncProtocol

/// Controls Music.app on this Mac via AppleScript. Needs the Automation permission for "Music".
///
/// NSAppleScript is not thread-safe, so every call is serialized on the main actor. Scripts are
/// short (<50 ms) and status is only polled while clients are connected.
@MainActor
public final class MusicController {
    public init() {}

    public enum Action: String, Sendable {
        case playpause, play, pause, next = "next track", previous = "previous track"
    }

    public func perform(_ action: Action) throws {
        try run("tell application \"Music\" to \(action.rawValue)")
    }

    public func setVolume(_ volume: Int) throws {
        try run("tell application \"Music\" to set sound volume to \(max(0, min(100, volume)))")
    }

    public func status() -> UIState.Music {
        let script = """
        if application "Music" is running then
            tell application "Music"
                set out to (player state as text)
                set out to out & linefeed & (sound volume as text)
                try
                    set t to current track
                    set out to out & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t)
                    set out to out & linefeed & ((duration of t) as text) & linefeed & ((player position) as text)
                end try
                return out
            end tell
        else
            return "notrunning"
        end if
        """
        guard let text = try? run(script), text != "notrunning" else { return UIState.Music(running: false) }
        let lines = text.components(separatedBy: "\n")
        func line(_ i: Int) -> String? { i < lines.count && !lines[i].isEmpty ? lines[i] : nil }
        return UIState.Music(
            running: true,
            state: line(0) ?? "stopped",
            name: line(2),
            artist: line(3),
            album: line(4),
            duration: line(5).flatMap(Self.number),
            position: line(6).flatMap(Self.number),
            volume: line(1).flatMap { Int($0) }
        )
    }

    public func playlists() throws -> [String] {
        let text = try run("""
        tell application "Music"
            set out to ""
            repeat with p in (user playlists whose special kind is none)
                set out to out & (name of p) & linefeed
            end repeat
            return out
        end tell
        """)
        return text.split(separator: "\n").map(String.init)
    }

    public func playPlaylist(named name: String) throws {
        try run("tell application \"Music\" to play user playlist \"\(Self.escape(name))\"")
    }

    public func searchLibrary(_ query: String, limit: Int = 25) throws -> [LibraryTrack] {
        let text = try run("""
        tell application "Music"
            set found to search library playlist 1 for "\(Self.escape(query))"
            set out to ""
            set n to 0
            repeat with t in found
                set out to out & (persistent ID of t) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & linefeed
                set n to n + 1
                if n ≥ \(limit) then exit repeat
            end repeat
            return out
        end tell
        """)
        return text.split(separator: "\n").compactMap { row in
            let f = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return f.count >= 4 ? LibraryTrack(id: f[0], name: f[1], artist: f[2], album: f[3]) : nil
        }
    }

    public func playTrack(persistentID: String) throws {
        let id = persistentID.filter(\.isHexDigit)
        try run("tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \"\(id)\")")
    }

    @discardableResult
    private func run(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else { throw MusicError("Could not compile AppleScript") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            throw MusicError(error[NSAppleScript.errorMessage] as? String ?? "AppleScript error")
        }
        return result.stringValue ?? ""
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// AppleScript formats reals with the user's locale decimal separator.
    static func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: "."))
    }
}

public struct MusicError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}
