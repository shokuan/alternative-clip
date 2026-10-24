// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AlternativeClip",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AlternativeClip",
            path: "Sources/AlternativeClip",
            linkerSettings: [.linkedFramework("IOUSBHost"), .linkedFramework("IOKit")]
        )
    ]
)
