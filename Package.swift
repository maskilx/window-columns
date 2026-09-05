// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WindowColumns",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WindowColumns", targets: ["WindowColumns"]),
        .executable(name: "WindowColumnsGroupHost", targets: ["WindowColumnsGroupHost"]),
        .executable(name: "LayoutEngineChecks", targets: ["LayoutEngineChecks"]),
        .executable(name: "GroupHostIntegrationChecks", targets: ["GroupHostIntegrationChecks"]),
        .executable(name: "RuntimeGroupChecks", targets: ["RuntimeGroupChecks"])
    ],
    targets: [
        .target(
            name: "WindowColumnsCore",
            path: "Sources/WindowColumnsCore"
        ),
        .executableTarget(
            name: "WindowColumns",
            dependencies: ["WindowColumnsCore"],
            path: "Sources/WindowColumns"
        ),
        .executableTarget(
            name: "WindowColumnsGroupHost",
            dependencies: ["WindowColumnsCore"],
            path: "Sources/WindowColumnsGroupHost"
        ),
        .executableTarget(
            name: "LayoutEngineChecks",
            dependencies: ["WindowColumnsCore"],
            path: "Tests/WindowColumnsTests"
        ),
        .executableTarget(
            name: "GroupHostIntegrationChecks",
            path: "Tests/GroupHostIntegrationChecks"
        ),
        .testTarget(
            name: "WindowColumnsAppTests",
            dependencies: ["WindowColumns"],
            path: "Tests/WindowColumnsAppTests"
        ),
        .executableTarget(
            name: "RuntimeGroupChecks",
            path: "Tests/RuntimeGroupChecks"
        )
    ],
    swiftLanguageModes: [.v5]
)
