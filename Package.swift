// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "HeadsUp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "HeadsUp", targets: ["HeadsUp"])
    ],
    targets: [
        // All app code lives here so it can be depended on both by the
        // HeadsUp executable and by HeadsUpChecks (no XCTest.framework on
        // this machine, so checks run as a plain executable instead).
        .target(
            name: "HeadsUpKit",
            path: "Sources/HeadsUpKit",
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        .executableTarget(
            name: "HeadsUp",
            dependencies: ["HeadsUpKit"],
            path: "Sources/HeadsUp"
        ),
        .executableTarget(
            name: "HeadsUpChecks",
            dependencies: ["HeadsUpKit"],
            path: "Sources/HeadsUpChecks"
        )
    ]
)
