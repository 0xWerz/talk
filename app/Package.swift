// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Talk",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Talk",
            path: "Sources/Talk",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
