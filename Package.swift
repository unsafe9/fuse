// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Fuse",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Fuse",
            path: "Sources/Fuse"
        )
    ]
)
