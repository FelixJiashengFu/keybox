// swift-tools-version:5.9
// 密钥匣 KeyBox for macOS. scripts/build-app.sh turns the KeyBox executable into 密钥匣.app.
import PackageDescription

let package = Package(
    name: "KeyBox",
    platforms: [.macOS(.v13)],
    targets: [
        // Vault format, providers, key tester, env import: no UI, shared by the app and the tests.
        .target(name: "KeyBoxCore"),
        .executableTarget(name: "KeyBox", dependencies: ["KeyBoxCore"]),
        .testTarget(name: "KeyBoxCoreTests", dependencies: ["KeyBoxCore"]),
    ]
)
