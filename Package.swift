// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DriveDock",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "DriveDock",
            path: "Sources/DriveDock",
            linkerSettings: [
                .linkedFramework("NetFS"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
