import AppKit
import AVFoundation
import MusicControl
import SwiftUI
import SyncProtocol

struct SyncSpeakerApp: App {
    @State private var runner: NodeRunner

    /// Resume the saved role at launch, not when the menu is first opened, so the web UI is served right away.
    init() {
        let runner = NodeRunner(settings: SettingsStore(), music: MusicController())
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if let role = runner.settings.role {
            try? runner.start(role: role, leaderHost: runner.settings.leaderHost, webRoot: WebRoot.resolve(nil))
        }
        _runner = State(initialValue: runner)
    }

    var body: some Scene {
        MenuBarExtra("SyncSpeaker", systemImage: "hifispeaker.2.fill") {
            MenuContent(runner: runner)
                .frame(width: 360)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuContent: View {
    let runner: NodeRunner
    @State private var lines: [String] = []
    @State private var leaderHost = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SyncSpeaker").font(.headline)

            Picker("Role", selection: Binding(
                get: { runner.role.map { $0.rawValue } ?? "off" },
                set: { select($0) }
            )) {
                Text("Off").tag("off")
                Text("Leader (A)").tag(NodeRole.leader.rawValue)
                Text("Follower (B)").tag(NodeRole.follower.rawValue)
            }
            .pickerStyle(.segmented)

            if runner.role == .follower || runner.role == nil {
                HStack {
                    TextField("Leader host (blank = Bonjour)", text: $leaderHost)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { runner.settings.leaderHost = leaderHost.isEmpty ? nil : leaderHost }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.system(.caption, design: .monospaced)).lineLimit(2)
                }
            }

            Divider()

            HStack {
                if runner.role == .leader {
                    Button("Open Web UI") {
                        NSWorkspace.shared.open(URL(string: "http://localhost:\(SyncConstants.httpPort)")!)
                    }
                    Button("Calibrate Sync") { runner.calibrate() }
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .onAppear { leaderHost = runner.settings.leaderHost ?? "" }
        .task {
            while !Task.isCancelled {
                lines = runner.statusLines()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func select(_ tag: String) {
        guard let role = NodeRole(rawValue: tag) else {
            runner.stop()
            runner.settings.role = nil
            return
        }
        runner.settings.role = role
        runner.settings.leaderHost = leaderHost.isEmpty ? nil : leaderHost
        try? runner.start(role: role, leaderHost: runner.settings.leaderHost, webRoot: WebRoot.resolve(nil))
    }
}
