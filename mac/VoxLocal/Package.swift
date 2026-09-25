// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoxLocal",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "VoxLocal", targets: ["VoxLocal"])],
    dependencies: [.package(path: "../../RemoteScribe")],
    targets: [
        .executableTarget(
            name: "VoxLocal",
            dependencies: [.product(name: "RemoteScribeCore", package: "RemoteScribe")],
            path: "Sources/VoxLocal",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
