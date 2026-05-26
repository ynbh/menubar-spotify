// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MenuBarSpotify",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MenuBarSpotify", targets: ["MenuBarSpotify"])
    ],
    targets: [
        .executableTarget(
            name: "MenuBarSpotify",
            path: "Sources/MenuBarSpotify"
        )
    ]
)
