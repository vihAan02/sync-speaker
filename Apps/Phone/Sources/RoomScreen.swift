import SwiftUI
import SyncProtocol

/// Room tab: scan the room, tap each MacBook in the camera view to place it, then walk around and listen.
struct RoomScreen: View {
    let connection: LeaderConnection
    let tracker: RoomTracker
    @State private var selected: SpeakerID = .a
    @State private var showMap = true
    @State private var showConnect = false
    @State private var notice: String?
    @State private var placements = 0

    var body: some View {
        ZStack {
            if RoomTracker.isSupported {
                ARRoomView(session: tracker.session, overlay: overlay, onTap: handleTap).ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
            VStack(spacing: 10) {
                StatusBar(connection: connection, tracker: tracker) { showConnect = true }
                if [.scanning, .placing, .listening].contains(tracker.phase), RoomTracker.isSupported {
                    StepIndicator(phase: tracker.phase)
                }
                if let banner {
                    Label(banner, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.orange.opacity(0.9), in: Capsule())
                        .foregroundStyle(.black)
                        .transition(.opacity)
                }
                if tracker.phase == .placing, RoomTracker.isSupported {
                    Text(tracker.anchors[selected] == nil
                         ? "Tap MacBook \(selected.rawValue) on screen"
                         : "Tap to move MacBook \(selected.rawValue)")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                card
            }
            .padding()
            .animation(.snappy, value: tracker.phase)
            .animation(.snappy, value: banner)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: placements)
        .sheet(isPresented: $showConnect) {
            ConnectSheet(connection: connection)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: connection.isConnected) { _, connected in
            if connected { showConnect = false }
        }
    }

    private var overlay: RoomOverlay {
        var speakers: [SpeakerID: RoomOverlay.Speaker] = [:]
        if connection.isConnected {
            for node in connection.state?.nodes ?? [] {
                speakers[node.speaker] = .init(channel: node.target.channel, delayMs: node.target.delaySeconds * 1000,
                                               gain: node.target.gain)
            }
        }
        return RoomOverlay(phase: tracker.phase, selected: tracker.phase == .placing ? selected : nil,
                           showMap: showMap, following: connection.state?.spatialMode != .off, speakers: speakers)
    }

    private var banner: String? {
        if let notice { return notice }
        if tracker.interrupted { return "Tracking paused. Point at the room to recover." }
        return nil
    }

    @ViewBuilder private var card: some View {
        if let failure = tracker.failure {
            MessageCard(title: "AR stopped", message: failure, systemImage: "exclamationmark.triangle")
        } else if !RoomTracker.isSupported {
            MessageCard(title: "Room mapping needs an iPhone",
                        message: "ARKit isn't available here. Run SyncSpeaker on an iPhone to scan your room and place the MacBooks. "
                            + "The Remote tab still works.",
                        systemImage: "arkit") {
                Button(connection.isConnected ? "Connected" : "Connect to leader") { showConnect = true }
                    .buttonStyle(.bordered)
                    .disabled(connection.isConnected)
            }
        } else {
            switch tracker.phase {
            case .choose:
                ChooseCard(tracker: tracker)
            case .relocalizing:
                RelocalizingCard(tracker: tracker)
            case .scanning:
                ScanCard(tracker: tracker)
            case .placing:
                PlaceCard(tracker: tracker, selected: $selected)
            case .listening:
                ListenCard(connection: connection, tracker: tracker, showMap: $showMap) { showConnect = true }
            }
        }
    }

    private func handleTap(_ tap: ARRoomView.Tap) {
        guard tracker.phase == .placing else { return }
        switch tap {
        case .marker(let speaker):
            selected = speaker
        case .surface(let point):
            tracker.placeSpeaker(selected, at: point)
            placements += 1
            // Move on to the next MacBook still waiting for a spot.
            if let next = SpeakerID.allCases.first(where: { tracker.anchors[$0] == nil }) { selected = next }
        case .miss:
            flash("Nothing mapped there yet. Scan that spot, then tap again.")
        }
    }

    private func flash(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if notice == text { notice = nil }
        }
    }
}

// MARK: Chrome

private struct StatusBar: View {
    let connection: LeaderConnection
    let tracker: RoomTracker
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onConnect) {
                Label(connectionText, systemImage: connection.isConnected ? "wifi" : "wifi.exclamationmark")
                    .lineLimit(1)
            }
            .tint(.primary)
            Spacer()
            Text(trackingText).foregroundStyle(.secondary)
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
        case .limited(let reason): reason.prefix(1).uppercased() + reason.dropFirst()
        case .notAvailable: "No AR"
        }
    }
}

private struct StepIndicator: View {
    let phase: RoomTracker.Phase

    private let steps: [(RoomTracker.Phase, String)] = [(.scanning, "Scan"), (.placing, "Place"), (.listening, "Listen")]

    var body: some View {
        let current = steps.firstIndex { $0.0 == phase } ?? 0
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 5) {
                    Image(systemName: index < current ? "checkmark.circle.fill" : "\(index + 1).circle\(index == current ? ".fill" : "")")
                    Text(step.1)
                }
                .foregroundStyle(index <= current ? .primary : .secondary)
                if index < steps.count - 1 {
                    Rectangle().fill(.secondary.opacity(0.4)).frame(width: 16, height: 1)
                }
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: Phase cards

private struct ChooseCard: View {
    let tracker: RoomTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restore your room?").font(.headline)
            Text("You've mapped a room before. Restore it to skip scanning and keep your MacBook spots, as long as they haven't moved.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                tracker.resumeSavedRoom()
            } label: {
                Label("Restore saved room", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button {
                tracker.scanNewRoom()
            } label: {
                Label("Scan a new room", systemImage: "viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .cardStyle()
    }
}

private struct RelocalizingCard: View {
    let tracker: RoomTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                Text("Looking for your room…").font(.headline)
            }
            Text("Point the phone at the MacBooks and the area around them, from about where you scanned last time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Scan a new room instead") { tracker.scanNewRoom() }
                .buttonStyle(.bordered)
        }
        .cardStyle()
    }
}

private struct ScanCard: View {
    let tracker: RoomTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan your room").font(.headline)
            Text(RoomTracker.supportsMesh
                 ? "Sweep the phone slowly over the floor, walls and desks, including both MacBooks. Colored mesh shows what's mapped."
                 : "Walk slowly around the room and point at the floor, walls and the desks your MacBooks sit on. Surfaces light up as they're found.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            MappingMeter(mapping: tracker.mapping, area: tracker.surfaceArea)
            if RoomTracker.supportsMesh { ClassLegend() }

            Button {
                tracker.finishScanning()
            } label: {
                Text(tracker.isReadyToPlace ? "Done, place MacBooks" : "Keep scanning…")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!tracker.isReadyToPlace)
            if let notice = tracker.roomNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }
}

private struct MappingMeter: View {
    let mapping: RoomTracker.Mapping
    let area: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(1...3, id: \.self) { level in
                    Capsule()
                        .fill(level <= mapping.rawValue ? Color.green : Color.secondary.opacity(0.25))
                        .frame(height: 6)
                }
            }
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.1f m² mapped", area)).monospacedDigit()
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .animation(.easeOut, value: mapping)
    }

    private var label: String {
        switch mapping {
        case .notAvailable: "Starting"
        case .limited: "Mapping, keep moving"
        case .extending: "Good map, add more if you like"
        case .mapped: "This area is mapped"
        }
    }
}

private struct ClassLegend: View {
    private let items: [(String, Int)] = [("Floor", 2), ("Wall", 1), ("Table", 4), ("Seat", 5)]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(items, id: \.1) { name, index in
                HStack(spacing: 4) {
                    Circle().fill(Color(uiColor: RoomScene.classColors[index])).frame(width: 8, height: 8)
                    Text(name)
                }
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

private struct PlaceCard: View {
    let tracker: RoomTracker
    @Binding var selected: SpeakerID

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Place your MacBooks").font(.headline)
            Picker("MacBook", selection: $selected) {
                ForEach(SpeakerID.allCases, id: \.self) { speaker in
                    Text("MacBook \(speaker.rawValue)").tag(speaker)
                }
            }
            .pickerStyle(.segmented)

            ForEach(SpeakerID.allCases, id: \.self) { speaker in
                PlacementRow(tracker: tracker, speaker: speaker, selected: speaker == selected)
            }

            if let spacing = tracker.anchorSpacing {
                Text(String(format: "MacBooks are %.2f m apart", spacing))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Menu {
                    Button("Use phone position for MacBook \(selected.rawValue)") {
                        tracker.placeSpeakerAtPhone(selected)
                    }
                    Button("Scan more of the room") { tracker.scanMore() }
                    Button("Start over", role: .destructive) { tracker.scanNewRoom() }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                Spacer()
                Button {
                    tracker.startListening()
                } label: {
                    Label("Start listening", systemImage: "ear")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(tracker.anchors.count < SpeakerID.allCases.count)
            }
            Text("Tip: for the most accurate spot, hold the phone against a MacBook and choose “Use phone position” from the ⋯ menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }
}

private struct PlacementRow: View {
    let tracker: RoomTracker
    let speaker: SpeakerID
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tracker.anchors[speaker] == nil ? "circle.dashed" : "checkmark.circle.fill")
                .foregroundStyle(tracker.anchors[speaker] == nil ? Color.secondary : Color.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("MacBook \(speaker.rawValue)").font(.subheadline.weight(.semibold))
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                Text("Selected")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.green.opacity(0.25), in: Capsule())
            }
        }
    }

    private var detail: String {
        guard let distance = tracker.distance(to: speaker) else { return "Not placed. Tap it in the camera view" }
        return String(format: "Placed · %.2f m from you", distance)
    }
}

private struct ListenCard: View {
    let connection: LeaderConnection
    let tracker: RoomTracker
    @Binding var showMap: Bool
    let onConnect: () -> Void
    @State private var pendingFollow: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Walk around and listen").font(.headline)
            if !connection.isConnected {
                HStack {
                    Label("Connect to your leader Mac to hear it", systemImage: "wifi.exclamationmark")
                        .font(.caption)
                    Spacer()
                    Button("Connect", action: onConnect).buttonStyle(.bordered).controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                ForEach(SpeakerID.allCases, id: \.self) { speaker in
                    SpeakerTile(connection: connection, tracker: tracker, speaker: speaker)
                }
            }
            RoomMiniMap(tracker: tracker, state: connection.state).frame(height: 100)

            HStack(spacing: 8) {
                ChipToggle(title: "Follow me", systemImage: "figure.walk", isOn: Binding(
                    get: { pendingFollow ?? (connection.state?.spatialMode != .off) },
                    set: { value in
                        pendingFollow = value
                        connection.send(.spatialMode(value ? .sweetSpot : .off))
                    }))
                ChipToggle(title: "Lock spot", systemImage: "lock", isOn: Binding(
                    get: { tracker.locked },
                    set: { tracker.setLocked($0) }))
                ChipToggle(title: "Map", systemImage: "square.grid.3x3", isOn: $showMap)
            }

            HStack {
                Button("Move MacBooks") { tracker.editSpeakers() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("New scan", role: .destructive) { tracker.scanNewRoom() }
                    .buttonStyle(.bordered)
            }
            Text(tracker.roomNotice ?? "Turn Follow me off and on to hear the difference. Lock your spot to put the phone down.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
        .onChange(of: connection.state?.spatialMode) { pendingFollow = nil }
    }
}

private struct SpeakerTile: View {
    let connection: LeaderConnection
    let tracker: RoomTracker
    let speaker: SpeakerID

    var body: some View {
        let node = connection.isConnected ? connection.state?.nodes.first { $0.speaker == speaker } : nil
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("MacBook \(speaker.rawValue)").font(.caption.weight(.semibold))
                Spacer()
                if let node {
                    Text(node.target.channel == .mono ? "Mono" : node.target.channel.rawValue)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Self.color(node.target.channel), in: Capsule())
                        .foregroundStyle(.black)
                }
            }
            Text(tracker.distance(to: speaker).map { String(format: "%.2f m", $0) } ?? "–")
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(node.map { String(format: "%.1f ms · %+.1f dB", $0.target.delaySeconds * 1000,
                                   20 * log10(max($0.target.gain, 0.001))) } ?? "Not connected")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    static func color(_ channel: SpeakerRender.Channel) -> Color {
        switch channel {
        case .left: Color(uiColor: SpeakerMarker.leftColor)
        case .right: Color(uiColor: SpeakerMarker.rightColor)
        case .mono: Color(white: 0.85)
        }
    }
}

private struct ChipToggle: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.bordered)
        .tint(isOn ? .accentColor : .secondary)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

private struct MessageCard<Actions: View>: View {
    let title: String
    let message: String
    let systemImage: String
    @ViewBuilder var actions: Actions

    init(title: String, message: String, systemImage: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            actions
        }
        .cardStyle()
    }
}

// MARK: Connect

struct ConnectSheet: View {
    let connection: LeaderConnection
    @State private var manualHost = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if connection.leaders.isEmpty {
                        Label("Looking for SyncSpeaker on this network…", systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(connection.leaders) { leader in
                        Button {
                            connection.connect(to: leader)
                        } label: {
                            Label(leader.name, systemImage: "laptopcomputer")
                        }
                    }
                } header: {
                    Text("Leader Macs")
                } footer: {
                    if let error = connection.lastError {
                        Label(error + " Retrying…", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                Section("Or enter a host") {
                    HStack {
                        TextField("MacBook.local", text: $manualHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { connection.connect(manualHost: manualHost) }
                        Button("Go") { connection.connect(manualHost: manualHost) }
                    }
                }
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: Mini map

/// Top-down sketch of the placed speakers and the listener, colored by the channel each speaker plays.
struct RoomMiniMap: View {
    let tracker: RoomTracker
    let state: UIState?

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
            let m = screen(me)
            for (speaker, anchor) in tracker.anchors {
                let s = screen(SIMD2(anchor.x, anchor.z))
                let channel = state?.nodes.first { $0.speaker == speaker }?.target.channel
                var ray = Path()
                ray.move(to: s)
                ray.addLine(to: m)
                context.stroke(ray, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                context.fill(Path(roundedRect: CGRect(x: s.x - 14, y: s.y - 10, width: 28, height: 20), cornerRadius: 5),
                             with: .color(channel.map(SpeakerTile.color) ?? .primary))
                context.draw(Text(speaker.rawValue).font(.caption.bold()).foregroundColor(channel == nil ? Color(uiColor: .systemBackground) : .black),
                             at: s)
            }
            var arrow = Path()
            arrow.move(to: m)
            arrow.addLine(to: CGPoint(x: m.x + CGFloat(tracker.forward.x) * 22, y: m.y + CGFloat(tracker.forward.y) * 22))
            context.stroke(arrow, with: .color(.blue), lineWidth: 3)
            context.fill(Path(ellipseIn: CGRect(x: m.x - 7, y: m.y - 7, width: 14, height: 14)), with: .color(.blue))
        }
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension View {
    func cardStyle() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
