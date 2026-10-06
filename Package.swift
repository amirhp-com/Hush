// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hush",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "HushCore", path: "Sources/HushCore"),
        .executableTarget(
            name: "Hush",
            dependencies: ["HushCore"],
            path: "Sources/Hush",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(name: "HushCoreTests", dependencies: ["HushCore"], path: "Tests/HushCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
