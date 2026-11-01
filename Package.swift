// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Acronome",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Acronome",
            path: "Sources/Acronome",
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
