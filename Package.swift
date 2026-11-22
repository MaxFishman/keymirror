// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "keymirror",
    platforms: [
        .macOS(.v11)
    ],
    targets: [
        .executableTarget(
            name: "keymirror",
            path: "Sources/keymirror"
        )
    ]
)
