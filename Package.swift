// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sill",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Sill",
            path: "Sources/Sill",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
