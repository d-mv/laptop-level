// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "laptop-level",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "laptop-level",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .testTarget(
            name: "laptop-levelTests",
            dependencies: ["laptop-level"]
        ),
    ]
)
