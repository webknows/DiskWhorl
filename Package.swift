// swift-tools-version:5.9
// DiskWhorl: a visual disk-space analyzer for macOS.
// Requires Swift 5.9 or later (Xcode 15+, or the Command Line Tools); builds in Swift 5 language mode.

import PackageDescription

let package = Package(
    name: "DiskWhorl",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "DiskWhorl",
            path: "Sources/DiskWhorl",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
