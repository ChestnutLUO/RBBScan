// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "videoscan",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../PasscodeCore")],
    targets: [
        .executableTarget(name: "videoscan", dependencies: ["PasscodeCore"]),
    ]
)
