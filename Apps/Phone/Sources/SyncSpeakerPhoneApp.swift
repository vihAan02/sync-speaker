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
                tracker.onMessage = { [connection] message in connection.send(message) }
                connection.onConnected = { [connection, tracker] in tracker.leaderSync().forEach(connection.send) }
                connection.startBrowsing()
                tracker.start()
            }
        }
    }
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
