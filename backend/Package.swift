// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TremorBackend",
    platforms: [
       .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // --- 1. 在這裡加入了 JWT 的原始碼位址 ---
        .package(url: "https://github.com/vapor/jwt.git", from: "4.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "TremorBackend",
            dependencies: [
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                // --- 2. 在這裡加入了 JWT 模組的引用 ---
                .product(name: "JWT", package: "jwt"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "TremorBackendTests",
            dependencies: [
                .target(name: "TremorBackend"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            swiftSettings: swiftSettings
        )
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
] }
