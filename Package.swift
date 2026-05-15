// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OWAWidget",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // Sparkle 2 for in-app auto-updates with EdDSA-signed artifacts.
        // Distributed as a binary xcframework + sign_update / generate_keys CLI tools.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "OWAWidget",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
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
            resources: [],
            linkerSettings: [
                // Sparkle.framework is dropped into Contents/Frameworks at bundle time.
                // The dynamic linker needs an rpath relative to the executable to find it.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "OWAWidgetTests",
            dependencies: ["OWAWidget"],
            path: "Tests/OWAWidgetTests"
        )
    ]
)
