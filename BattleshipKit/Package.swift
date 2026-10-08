// swift-tools-version: 6.0
import PackageDescription

// Shared code for the Battleships iOS app and server.
//
// - BattleshipCore:   pure game engine (rules, fleets, battles, computer opponents).
// - BattleshipAPI:    the wire contract (request/response/event types) spoken by app and server.
// - BattleshipClient: networking SDK the app uses to talk to the server (HTTP + WebSocket).
let package = Package(
    name: "BattleshipKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BattleshipCore", targets: ["BattleshipCore"]),
        .library(name: "BattleshipAPI", targets: ["BattleshipAPI"]),
        .library(name: "BattleshipClient", targets: ["BattleshipClient"]),
    ],
    targets: [
        .target(name: "BattleshipCore"),
        .target(name: "BattleshipAPI", dependencies: ["BattleshipCore"]),
        .target(name: "BattleshipClient", dependencies: ["BattleshipAPI"]),
        .testTarget(name: "BattleshipCoreTests", dependencies: ["BattleshipCore"]),
        .testTarget(name: "BattleshipAPITests", dependencies: ["BattleshipAPI"]),
        .testTarget(name: "BattleshipClientTests", dependencies: ["BattleshipClient"]),
    ]
)
