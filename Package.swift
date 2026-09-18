// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HoldImg",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "KeyboardShortcuts",
            path: "Vendor/KeyboardShortcuts/Sources/KeyboardShortcuts",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "HoldImg",
            dependencies: ["KeyboardShortcuts"],
            path: "Sources/HoldImg"
        )
    ]
)
