// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "toccata-overlay",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "toccata-overlay",
            path: ".",
            sources: ["Sources/toccata-overlay"],
            resources: [.process("Resources")]
        )
    ]
)
