import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
import SyncProtocol

public protocol ControlServerDelegate: Sendable {
    func currentState() async -> UIState
    /// Handles a UI command; the optional reply goes only to the sender.
    func handle(command: UICommand) async -> UIReply?
    func handle(phone: PhoneMessage) async
    func phoneConnectionChanged(connected: Bool) async
}

/// Serves the web UI and the `/ws/ui` + `/ws/phone` WebSockets on the leader.
public struct ControlServer: Sendable {
    public let port: Int
    public let webRoot: String
    public let delegate: any ControlServerDelegate

    public init(port: Int = Int(SyncConstants.httpPort), webRoot: String, delegate: any ControlServerDelegate) {
        self.port = port
        self.webRoot = webRoot
        self.delegate = delegate
    }

    public func run() async throws {
        let delegate = self.delegate
        var logger = Logger(label: "syncspeaker.http")
        logger.logLevel = .warning

        let router = Router()
        router.add(middleware: FileMiddleware(webRoot, searchForIndexHtml: true, logger: logger))
        router.get("/api/state") { _, _ -> Response in
            let body = try JSONEncoder().encode(await delegate.currentState())
            return Response(status: .ok, headers: [.contentType: "application/json", .cacheControl: "no-store"],
                            body: .init(byteBuffer: ByteBuffer(bytes: body)))
        }

        let ws = Router(context: BasicWebSocketRequestContext.self)
        ws.ws("/ws/ui") { inbound, outbound, _ in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    // Push state at 5 Hz, skipping unchanged snapshots.
                    var last: Data?
                    while !Task.isCancelled {
                        let data = try JSONEncoder().encode(["state": await delegate.currentState()])
                        if data != last {
                            try await outbound.write(.text(String(decoding: data, as: UTF8.self)))
                            last = data
                        }
                        try await Task.sleep(for: .milliseconds(200))
                    }
                }
                group.addTask {
                    for try await message in inbound.messages(maxSize: 1 << 16) {
                        guard case .text(let text) = message,
                              let command = try? JSONDecoder().decode(UICommand.self, from: Data(text.utf8)) else { continue }
                        if let reply = await delegate.handle(command: command) {
                            let data = try JSONEncoder().encode(["reply": reply])
                            try await outbound.write(.text(String(decoding: data, as: UTF8.self)))
                        }
                    }
                }
                // Whichever side ends first (usually the client closing) tears down the other.
                try await group.next()
                group.cancelAll()
            }
        }
        ws.ws("/ws/phone") { inbound, outbound, _ in
            await delegate.phoneConnectionChanged(connected: true)
            defer { Task { await delegate.phoneConnectionChanged(connected: false) } }
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        let state = await delegate.currentState()
                        let data = try JSONEncoder().encode(["state": state])
                        try await outbound.write(.text(String(decoding: data, as: UTF8.self)))
                        try await Task.sleep(for: .milliseconds(500))
                    }
                }
                group.addTask {
                    for try await message in inbound.messages(maxSize: 1 << 16) {
                        guard case .text(let text) = message,
                              let phone = try? JSONDecoder().decode(PhoneMessage.self, from: Data(text.utf8)) else { continue }
                        await delegate.handle(phone: phone)
                    }
                }
                try await group.next()
                group.cancelAll()
            }
        }

        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: ws),
            // "::" listens on IPv6 and IPv4 alike; iPhone Personal Hotspot is IPv6-only, so "0.0.0.0" is unreachable there.
            configuration: .init(address: .hostname("::", port: port), serverName: "SyncSpeaker"),
            logger: logger
        )
        try await app.run()
    }
}
