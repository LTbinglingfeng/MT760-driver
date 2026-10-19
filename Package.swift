// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MT760Control",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MT760Control", targets: ["MT760App"]),
        .executable(name: "mt760-diagnostics", targets: ["MT760Diagnostics"]),
        .executable(name: "mt760-read-helper", targets: ["MT760ReadHelper"])
    ],
    targets: [
        .target(name: "MT760Core", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "MT760App", dependencies: ["MT760Core"]),
        .executableTarget(name: "MT760Diagnostics", dependencies: ["MT760Core"]),
        .executableTarget(name: "MT760ReadHelper", dependencies: ["MT760Core"]),
        .testTarget(name: "MT760CoreTests", dependencies: ["MT760Core"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MT760AppTests", dependencies: ["MT760App", "MT760Core"])
    ]
)
