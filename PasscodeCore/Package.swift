// swift-tools-version:6.0
import Foundation
import PackageDescription

let package = Package(
    name: "PasscodeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PasscodeCore", targets: ["PasscodeCore"]),
    ],
    targets: [
        .target(name: "PasscodeCore"),
    ]
)

// The tests use real passcodes, so they are kept out of git and exist only on the machine that scanned them.
if FileManager.default.fileExists(atPath: Context.packageDirectory + "/Tests/PasscodeCoreTests") {
    package.targets.append(.testTarget(name: "PasscodeCoreTests", dependencies: ["PasscodeCore"]))
}
