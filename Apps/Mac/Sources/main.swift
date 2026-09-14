import AppKit
import Foundation
import MusicControl
import SyncProtocol

/// Usage:
///   SyncSpeaker                                       menu-bar app (role chosen in the menu)
///   SyncSpeaker --role leader [--source tap|tone] [--web-root DIR] [--volume 0...1]
///   SyncSpeaker --role follower [--leader-host HOST]
///   SyncSpeaker --capture-test SECONDS OUT.wav        milestone-1 spike: record the system tap to a WAV
struct CommandLineOptions {
    var role: NodeRole?
    var source = LeaderSource.Kind.systemTap
    var leaderHost: String?
    var webRoot: String?
    var volume: Double?
    var captureTest: (seconds: Double, path: String)?

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--role": role = it.next().flatMap(NodeRole.init(rawValue:))
            case "--source": source = it.next().flatMap(LeaderSource.Kind.init(rawValue:)) ?? .systemTap
            case "--leader-host": leaderHost = it.next()
            case "--web-root": webRoot = it.next()
            case "--volume": volume = it.next().flatMap(Double.init)
            case "--capture-test":
                if let s = it.next().flatMap(Double.init), let p = it.next() { captureTest = (s, p) }
            default: break
            }
        }
    }
}

enum WebRoot {
    /// Bundled `Resources/web`, else `web/dist` next to the working directory (development).
    static func resolve(_ override: String?) -> String {
        if let override { return override }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("web"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.html").path) {
            return bundled.path
        }
        return FileManager.default.currentDirectoryPath + "/web/dist"
    }
}

let options = CommandLineOptions(CommandLine.arguments)

if let test = options.captureTest {
    do {
        try CaptureTest.run(seconds: test.seconds, path: test.path)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("capture test failed: \(error)\n".utf8))
        exit(1)
    }
} else if let role = options.role {
    // Headless node for scripted runs and testing.
    setvbuf(stdout, nil, _IOLBF, 0)
    let settings = SettingsStore()
    settings.masterVolumeOverride = options.volume
    MainActor.assumeIsolated {
        let runner = NodeRunner(settings: settings, music: MusicController())
        do {
            try runner.start(role: role, source: options.source, leaderHost: options.leaderHost ?? settings.leaderHost,
                             webRoot: WebRoot.resolve(options.webRoot))
            print("SyncSpeaker \(role.rawValue) running. Ctrl-C to stop.")
            if role == .leader { print("Web UI: http://\(HostNames.localHostName):\(SyncConstants.httpPort)") }
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated { print(runner.summaryLine()) }
            }
        } catch {
            FileHandle.standardError.write(Data("failed to start: \(error)\n".utf8))
            exit(1)
        }
        _ = Unmanaged.passRetained(runner)
    }
    RunLoop.main.run()
} else {
    SyncSpeakerApp.main()
}
