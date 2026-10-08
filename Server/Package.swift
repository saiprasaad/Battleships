// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BattleshipServer",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "../BattleshipKit"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.122.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.14.0"),
        .package(url: "https://github.com/vapor/apns.git", from: "5.0.0"),
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "BattleshipServer",
            dependencies: [
                .product(name: "BattleshipCore", package: "BattleshipKit"),
                .product(name: "BattleshipAPI", package: "BattleshipKit"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "VaporAPNS", package: "apns"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "BattleshipServerTests",
            dependencies: [
                .target(name: "BattleshipServer"),
                .product(name: "BattleshipClient", package: "BattleshipKit"),
                .product(name: "XCTVapor", package: "vapor"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "CryptoExtras", package: "swift-crypto"),
            ]
        ),
    ]
)
