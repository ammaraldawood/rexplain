// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Rexplain",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "rexplain", targets: ["Rexplain"]),
    ],
    targets: [
        .target(
            name: "RexplainCore",
            path: "Sources/RexplainCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Rexplain",
            dependencies: ["RexplainCore"],
            path: "Sources/Rexplain",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RexplainTests",
            dependencies: ["RexplainCore"],
            path: "Tests/RexplainTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
