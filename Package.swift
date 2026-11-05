// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SSPManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SSPManager", path: "Sources/SSPManager")
    ]
)
