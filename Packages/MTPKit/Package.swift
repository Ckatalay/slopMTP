// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MTPKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MTPKit", targets: ["MTPKit"]),
    ],
    targets: [
        .target(
            name: "MTPKit",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
            ]
        ),
        .executableTarget(name: "mtp-probe", dependencies: ["MTPKit"]),
        .testTarget(name: "MTPKitTests", dependencies: ["MTPKit"]),
    ]
)
