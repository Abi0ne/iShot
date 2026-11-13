// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "iShot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "iShot", targets: ["iShot"])
    ],
    targets: [
        .executableTarget(
            name: "iShot",
            path: "Sources/iShot",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Vision"),
                .linkedFramework("VisionKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
