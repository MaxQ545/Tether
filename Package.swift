// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Tether",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tether", targets: ["Tether"])
    ],
    targets: [
        .executableTarget(
            name: "Tether",
            path: "Sources/Tether"
        )
    ]
)
