// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Luka",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "LukaCore"),
        .executableTarget(
            name: "Luka",
            dependencies: ["LukaCore"],
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("Carbon")]
        ),
        .testTarget(
            name: "LukaCoreTests",
            dependencies: ["LukaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
