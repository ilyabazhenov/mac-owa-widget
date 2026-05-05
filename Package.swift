// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OWAWidget",
    defaultLocalization: "en",
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
                // Localizations are copied to app bundle by Makefile.
                // Keeping them out of SPM resources avoids runtime dependency
                // on OWAWidget_OWAWidget.bundle in release app execution.
                "Resources",
            ],
            resources: []
        ),
        .testTarget(
            name: "OWAWidgetTests",
            dependencies: ["OWAWidget"],
            path: "Tests/OWAWidgetTests"
        )
    ]
)
