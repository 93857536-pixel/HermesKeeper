// swift-tools-version:5.9
// HermesKeeper — keeps the Mac awake while hermes agent is busy; releases after a 5-min grace when idle.
import PackageDescription

let package = Package(
    name: "HermesKeeper",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "HermesKeeper",
            path: "Sources/HermesKeeper"
        )
    ]
)
