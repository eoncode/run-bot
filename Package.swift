// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "RunBot",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "RunBotCore",
            targets: ["RunBotCore"]
        ),
        .library(
            name: "AppUpdater",
            targets: ["AppUpdater"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0")
    ],
    targets: [
        .target(
            name: "AppUpdater",
            dependencies: [],
            path: "Sources/AppUpdater",
            exclude: ["README.md"],
            // Valid per-target API since swift-tools-version:5.4 (used here with 6.2).
            // The package-level platforms: [.macOS(.v26)] already covers this target by
            // inheritance — this declaration is intentionally redundant: it makes the
            // macOS-only requirement self-documenting on the target itself so the constraint
            // travels with AppUpdater if it is ever extracted into a standalone repo.
            platforms: [.macOS(.v26)],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .target(
            name: "RunBotCore",
            dependencies: [
                "AppUpdater",
                .product(name: "Collections", package: "swift-collections")
            ],
            path: "Sources/RunBotCore",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .executableTarget(
            name: "RunBot",
            dependencies: ["RunBotCore", "AppUpdater"],
            path: "Sources/RunBot",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "RunBotCoreTests",
            dependencies: [
                "RunBotCore",
                .product(name: "Collections", package: "swift-collections")
            ],
            path: "Tests/RunBotCoreTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "AppUpdaterTests",
            dependencies: [
                "AppUpdater"
            ],
            path: "Tests/AppUpdaterTests",
            // See comment on AppUpdater target above — same rationale.
            platforms: [.macOS(.v26)],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        )
    ]
)
