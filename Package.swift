// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Fuse",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "LidGuardShared",
            path: "Sources/LidGuardShared"
        ),
        .executableTarget(
            name: "Fuse",
            dependencies: ["LidGuardShared"],
            path: "Sources/Fuse"
        ),
        .executableTarget(
            name: "FuseLidGuard",
            dependencies: ["LidGuardShared"],
            path: "Sources/FuseLidGuard"
        )
    ]
)
