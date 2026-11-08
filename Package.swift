// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "laptop-level",
    platforms: [.macOS(.v12)],
    targets: [
        // All logic, kept testable; the executable is a one-line entry point.
        .target(
            name: "LaptopLevelCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "laptop-level",
            dependencies: ["LaptopLevelCore"]
        ),
        .testTarget(
            name: "LaptopLevelCoreTests",
            dependencies: ["LaptopLevelCore"]
        ),
    ]
)
