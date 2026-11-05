// swift-tools-version:5.9
import PackageDescription

// Pure, platform-independent client rules. Deliberately has no dependency on
// Martin or Apple frameworks so `swift test` also runs on Linux.
let package = Package(
    name: "RoostChatCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "RoostChatCore", targets: ["RoostChatCore"])],
    targets: [
        .target(name: "RoostChatCore"),
        .testTarget(name: "RoostChatCoreTests", dependencies: ["RoostChatCore"]),
    ]
)
