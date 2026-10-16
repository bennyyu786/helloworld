// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "dictate_insert",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "dictate_insert",
            path: "Sources/dictate_insert"
        )
    ]
)
