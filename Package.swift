// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AndroidSimulator",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SimulatorKit", targets: ["SimulatorKit"]),
        .executable(name: "AndroidSimulator", targets: ["AndroidSimulator"]),
        .executable(name: "droiddock", targets: ["SimulatorCLI"]),
        .executable(name: "android-simulator", targets: ["SimulatorCLI"]),
        .executable(name: "SimulatorProbe", targets: ["SimulatorProbe"])
    ],
    targets: [
        .target(name: "SimulatorKit"),
        .executableTarget(name: "AndroidSimulator", dependencies: ["SimulatorKit"]),
        .executableTarget(name: "SimulatorCLI", dependencies: ["SimulatorKit"]),
        .executableTarget(name: "SimulatorProbe", dependencies: ["SimulatorKit"]),
        .testTarget(name: "SimulatorKitTests", dependencies: ["SimulatorKit"]),
        .testTarget(name: "AndroidSimulatorTests", dependencies: ["AndroidSimulator", "SimulatorKit"])
    ],
    swiftLanguageModes: [.v5]
)
