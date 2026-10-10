// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "toccata-studio",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "toccata-studio",
            path: ".",
            sources: ["Sources"],
            resources: [.process("Resources")]
        )
    ]
)
