// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Koe",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "Koe",
            path: "Sources/Koe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
