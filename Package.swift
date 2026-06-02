// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Juicer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "Juicer",
            targets: ["Juicer"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Juicer",
            dependencies: [],
            path: "Sources/Juicer"
        )
    ]
)

