// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "guac_client",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "guac_client",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
