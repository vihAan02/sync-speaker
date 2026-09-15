import ARKit
import SceneKit
import SwiftUI
import SyncProtocol
import WebKit

@main
struct SyncSpeakerPhoneApp: App {
    @State private var connection = LeaderConnection()
    @State private var tracker = RoomTracker()

    var body: some Scene {
        WindowGroup {
            TabView {
                RoomScreen(connection: connection, tracker: tracker)
                    .tabItem { Label("Room", systemImage: "location.viewfinder") }
                RemoteScreen(connection: connection)
                    .tabItem { Label("Remote", systemImage: "hifispeaker.2") }
            }
            .onAppear {
                connection.startBrowsing()
                tracker.onPose = { [connection] pose in connection.send(.pose(pose)) }
                tracker.start()
            }
        }
    }
}

// MARK: Room (ARKit placement + live tracking)

struct RoomScreen: View {
    let connection: LeaderConnection
    let tracker: RoomTracker
    @State private var manualHost = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            ARCameraView(session: tracker.session).ignoresSafeArea()
            VStack(spacing: 12) {
                statusBar
                if case .connected = connection.status {
                    placementCard
                } else {
                    connectCard
                }
            }
            .padding()
        }
    }

    private var statusBar: some View {
        HStack {
            Label(connectionText, systemImage: "wifi").lineLimit(1)
            Spacer()
            Text(trackingText)
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var connectionText: String {
        switch connection.status {
        case .disconnected: "Not connected"
        case .connecting(let name): "Connecting to \(name)…"
        case .connected(let name): name
        }
    }

    private var trackingText: String {
        switch tracker.tracking {
        case .notStarted: "AR starting"
        case .normal: tracker.locked ? "Locked" : "Tracking"
        case .limited(let reason): reason.capitalized
        case .notAvailable: "No tracking"
        }
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect to your leader Mac").font(.headline)
            if connection.leaders.isEmpty {
                Text("Looking for SyncSpeaker on this Wi-Fi…").foregroundStyle(.secondary)
            }
            if let error = connection.lastError {
                Label(error + " Retrying…", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(connection.leaders) { leader in
                Button {
                    connection.connect(to: leader)
                } label: {
                    Label(leader.name, systemImage: "laptopcomputer")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
            HStack {
                TextField("or host, e.g. MacBook.local", text: $manualHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button("Go") { connection.connect(manualHost: manualHost) }
            }
        }
        .cardStyle()
    }

    private var placementCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if tracker.interrupted {
                Label("Tracking was interrupted. Place the speakers again.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ForEach(SpeakerID.allCases, id: \.self) { speaker in
                HStack {
                    VStack(alignment: .leading) {
                        Text("Speaker \(speaker.rawValue)").font(.headline)
                        Text(speakerDetail(speaker)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(tracker.anchors[speaker] == nil ? "Phone is touching it" : "Place again") {
                        connection.send(.anchor(tracker.placeSpeaker(speaker)))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(tracker.tracking != .normal)
                }
            }

            if let spacing = tracker.anchorSpacing {
                spacingRow(spacing)
            }

            RoomMiniMap(tracker: tracker).frame(height: 120)

            HStack {
                Toggle("Lock my spot", isOn: Binding(
                    get: { tracker.locked },
                    set: { value in
                        tracker.setLocked(value)
                        connection.send(.lock(value))
                    }))
                Button("Reset", role: .destructive) {
                    tracker.resetRoom()
                    connection.send(.resetRoom)
                }
            }
            Text("Hold the phone against each MacBook and tap its button. Then walk around; the speakers follow you. "
                + "Lock your spot to put the phone down.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private func speakerDetail(_ speaker: SpeakerID) -> String {
        guard let distance = tracker.distance(to: speaker) else { return "Not placed" }
        let node = connection.state?.nodes.first { $0.speaker == speaker }
        let delay = node.map { String(format: " · %.1f ms · %@", $0.target.delaySeconds * 1000, $0.target.channel.rawValue) } ?? ""
        return String(format: "%.2f m away", distance) + delay
    }

    private func spacingRow(_ spacing: Float) -> some View {
        let acoustic = connection.state?.calibration.baselineMeters
        let text: String
        if let acoustic {
            let diff = abs(Double(spacing) - acoustic) * 100
            text = String(format: "Spacing %.2f m (acoustic %.2f m, Δ %.0f cm)", spacing, acoustic, diff)
        } else {
            text = String(format: "Spacing %.2f m", spacing)
        }
        return Text(text).font(.caption.monospacedDigit())
    }
}

/// Top-down sketch of the placed speakers and the listener.
struct RoomMiniMap: View {
    let tracker: RoomTracker

    var body: some View {
        Canvas { context, size in
            var points = tracker.anchors.values.map { SIMD2($0.x, $0.z) }
            let me = SIMD2(tracker.position.x, tracker.position.z)
            points.append(me)
            let minX = points.map(\.x).min()! - 0.6, maxX = points.map(\.x).max()! + 0.6
            let minZ = points.map(\.y).min()! - 0.6, maxZ = points.map(\.y).max()! + 0.6
            let scale = min(Float(size.width) / (maxX - minX), Float(size.height) / (maxZ - minZ))
            func screen(_ p: SIMD2<Float>) -> CGPoint {
                CGPoint(x: CGFloat((p.x - (minX + maxX) / 2) * scale) + size.width / 2,
                        y: CGFloat((p.y - (minZ + maxZ) / 2) * scale) + size.height / 2)
            }
            for (speaker, anchor) in tracker.anchors {
                let s = screen(SIMD2(anchor.x, anchor.z))
                context.fill(Path(roundedRect: CGRect(x: s.x - 14, y: s.y - 10, width: 28, height: 20), cornerRadius: 5),
                             with: .color(.primary))
                context.draw(Text(speaker.rawValue).font(.caption.bold()).foregroundColor(Color(uiColor: .systemBackground)), at: s)
            }
            let m = screen(me)
            var arrow = Path()
            arrow.move(to: m)
            arrow.addLine(to: CGPoint(x: m.x + CGFloat(tracker.forward.x) * 22, y: m.y + CGFloat(tracker.forward.y) * 22))
            context.stroke(arrow, with: .color(.orange), lineWidth: 3)
            context.fill(Path(ellipseIn: CGRect(x: m.x - 7, y: m.y - 7, width: 14, height: 14)), with: .color(.orange))
        }
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ARCameraView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = false
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

// MARK: Remote (the leader's web UI)

struct RemoteScreen: View {
    let connection: LeaderConnection

    var body: some View {
        if let url = connection.webURL {
            WebView(url: url).ignoresSafeArea(edges: .bottom)
        } else {
            ContentUnavailableView("Not connected", systemImage: "hifispeaker.2",
                                   description: Text("Connect to a leader Mac on the Room tab."))
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if view.url?.host != url.host { view.load(URLRequest(url: url)) }
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
