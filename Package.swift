// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "chartAlwaysOnTopDesktop",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "chartAlwaysOnTopDesktopCore",
            targets: ["chartAlwaysOnTopDesktop"]
        ),
        .executable(
            name: "chartAlwaysOnTopDesktop",
            targets: ["chartAlwaysOnTopDesktopApp"]
        )
    ],
    targets: [
        .target(
            name: "chartAlwaysOnTopDesktop",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "chartAlwaysOnTopDesktopTests",
            dependencies: ["chartAlwaysOnTopDesktop"]
        ),
        .executableTarget(
            name: "chartAlwaysOnTopDesktopApp",
            dependencies: ["chartAlwaysOnTopDesktop"],
            path: "Sources/chartAlwaysOnTopDesktopApp"
        )
    ]
)
