// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenRec",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TokenRec",
            path: "Sources/TokenRec"
        ),
        .testTarget(
            name: "TokenRecTests",
            dependencies: ["TokenRec"],
            path: "Tests/TokenRecTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
