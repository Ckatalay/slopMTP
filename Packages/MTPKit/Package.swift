// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MTPKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MTPKit", targets: ["MTPKit"]),
    ],
    targets: [
        .target(
            name: "MTPKit",
            resources: [.process("Localizable.xcstrings")],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
            ]
        ),
        .executableTarget(name: "mtp-probe", dependencies: ["MTPKit"]),
        .testTarget(name: "MTPKitTests", dependencies: ["MTPKit"]),
    ]
)
