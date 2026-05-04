// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OWAWidget",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "OWAWidget",
            path: "OWAWidget",
            // Exclude non-Swift files so SPM doesn't try to bundle them
            exclude: [
                "Info.plist",
                "OWAWidget.entitlements",
                "OWAWidget-dev.entitlements",
            ]
        ),
        .testTarget(
            name: "OWAWidgetTests",
            dependencies: ["OWAWidget"],
            path: "Tests/OWAWidgetTests"
        )
    ]
)
