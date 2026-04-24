// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Sync",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sync", targets: ["Sync"])
    ],
    targets: [
        .executableTarget(
            name: "Sync",
            path: "Sources/Sync"
        )
    ]
)
