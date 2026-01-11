// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ikit", targets: ["iKit"])
    ],
    targets: [
        .executableTarget(
            name: "iKit",
            dependencies: [],
            path: "Sources/iKit"
        )
    ]
)