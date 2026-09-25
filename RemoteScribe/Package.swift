// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemoteScribe",
    platforms: [.macOS("15.0"), .iOS(.v16)],
    products: [
        .library(name: "RemoteScribeCore", targets: ["RemoteScribeCore"]),
        .executable(name: "RemoteScribeHost", targets: ["RemoteScribeHost"]),
        .executable(name: "RemoteScribeMac", targets: ["RemoteScribeMac"]),
        .executable(name: "RemoteScribeTestClient", targets: ["RemoteScribeTestClient"]),
        .executable(name: "RemoteScribeDiagnostics", targets: ["RemoteScribeDiagnostics"]),
        .executable(name: "RemoteScribeQRCode", targets: ["RemoteScribeQRCode"])
    ],
    targets: [
        .target(name: "RemoteScribeCore", path: "Core/Sources"),
        .executableTarget(
            name: "RemoteScribeHost",
            dependencies: ["RemoteScribeCore"],
            path: "MacServer/Sources",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "RemoteScribeMac",
            dependencies: ["RemoteScribeCore"],
            path: "MacMenuApp/Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "RemoteScribeTestClient",
            dependencies: ["RemoteScribeCore"],
            path: "MacServer/TestClient"
        ),
        .executableTarget(
            name: "RemoteScribeDiagnostics",
            dependencies: ["RemoteScribeCore"],
            path: "Core/Diagnostics"
        ),
        .executableTarget(
            name: "RemoteScribeQRCode",
            path: "WebClient/QRCodeTool",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage")
            ]
        ),
        .testTarget(
            name: "RemoteScribeCoreTests",
            dependencies: ["RemoteScribeCore"],
            path: "Core/Tests"
        )
    ]
)
