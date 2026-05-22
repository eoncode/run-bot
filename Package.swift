// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RunnerBar",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "RunnerBarLib",
            path: "Sources/RunnerBar",
            exclude: ["main.swift"]
        ),
        .executableTarget(
            name: "RunnerBar",
            dependencies: ["RunnerBarLib"],
            path: "Sources/RunnerBarMain"
        ),
        .testTarget(
            name: "RunnerBarTests",
            dependencies: ["RunnerBarLib"],
            path: "Tests/RunnerBarTests"
        )
    ]
)
