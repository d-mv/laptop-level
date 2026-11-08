// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "laptop-level",
    targets: [
        // C interop module that re-declares the private IOHIDEventSystemClient SPI.
        .target(name: "CHIDSPI"),
        .executableTarget(
            name: "laptop-level",
            dependencies: ["CHIDSPI"],
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
