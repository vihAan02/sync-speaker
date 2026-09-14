// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SyncSpeaker",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        // Shared with the iOS companion app.
        .library(name: "SyncProtocol", targets: ["SyncProtocol"]),
        .library(name: "SpatialPlanner", targets: ["SpatialPlanner"]),
        .executable(name: "SyncSpeaker", targets: ["SyncSpeakerMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
    ],
    targets: [
        // Real-time-safe C kernels: timeline buffer, playout renderer, capture FIFO.
        .target(name: "CDSP"),
        .target(name: "SyncProtocol"),
        .target(name: "ClockSync"),
        .target(name: "SpatialPlanner"),
        .target(name: "Calibration"),
        .target(name: "Playout", dependencies: ["CDSP", "SyncProtocol"]),
        .target(name: "AudioIO", dependencies: ["CDSP"]),
        .target(name: "Transport", dependencies: ["SyncProtocol", "ClockSync"]),
        .target(name: "MusicControl", dependencies: ["SyncProtocol"]),
        .target(
            name: "ControlServer",
            dependencies: [
                "SyncProtocol",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ]
        ),
        .executableTarget(
            name: "SyncSpeakerMac",
            dependencies: [
                "CDSP", "SyncProtocol", "ClockSync", "SpatialPlanner", "Calibration", "Playout",
                "AudioIO", "Transport", "MusicControl", "ControlServer",
            ],
            path: "Apps/Mac/Sources"
        ),
        .testTarget(name: "ClockSyncTests", dependencies: ["ClockSync"]),
        .testTarget(name: "SpatialPlannerTests", dependencies: ["SpatialPlanner"]),
        .testTarget(name: "CalibrationTests", dependencies: ["Calibration"]),
        .testTarget(name: "PlayoutTests", dependencies: ["Playout", "CDSP", "SyncProtocol"]),
        .testTarget(name: "SyncProtocolTests", dependencies: ["SyncProtocol"]),
    ]
)
