// swift-tools-version: 5.10
// SPM manifest used ONLY to run SlapDetector unit tests without Xcode.
// The actual .app is built by Packaging/build.sh which compiles both targets
// directly with swiftc and assembles the bundle.
import PackageDescription

let package = Package(
    name: "FreeSlapMacCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FreeSlapMacCore", targets: ["FreeSlapMacCore"]),
    ],
    targets: [
        .target(
            name: "FreeSlapMacCore",
            path: ".",
            exclude: [
                "App", "Shared", "Packaging", "Resources", "Tests",
                "Helper/main.swift",
                "Helper/HIDSensor.swift",
                "Helper/Info.plist",
                "Helper/com.freeslapmac.helper.plist",
            ],
            sources: ["Helper/SlapDetector.swift"]
        ),
        .testTarget(
            name: "FreeSlapMacCoreTests",
            dependencies: ["FreeSlapMacCore"],
            path: "Tests"
        ),
    ]
)
