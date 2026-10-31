// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Syntly",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SyntlyCore", targets: ["SyntlyCore"]),
        .executable(name: "Syntly", targets: ["Syntly"])
    ],
    targets: [
        .target(
            name: "SyntlyCore",
            path: "Sources/SyntlyCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "Syntly",
            dependencies: ["SyntlyCore"],
            path: "Sources/SyntlyApp"
        ),
        .testTarget(
            name: "SyntlyTests",
            dependencies: ["SyntlyCore"],
            path: "Tests/SyntlyTests"
        )
    ]
)
