// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ExtDisplayKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ExtDisplayKit", targets: ["ExtDisplayKit"]),
    ],
    targets: [
        .target(name: "ExtDisplayKit"),
        .testTarget(name: "ExtDisplayKitTests", dependencies: ["ExtDisplayKit"]),
    ]
)

