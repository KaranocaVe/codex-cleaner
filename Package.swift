// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexCleaner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexCleaner", targets: ["CodexCleaner"])
    ],
    targets: [
        .executableTarget(
            name: "CodexCleaner",
            path: "Sources/CodexCleaner",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "CodexCleanerTests",
            dependencies: ["CodexCleaner"],
            path: "Tests/CodexCleanerTests"
        )
    ]
)
