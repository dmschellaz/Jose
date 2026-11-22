// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "RedlineCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "RedlineCore", targets: ["RedlineCore"])],
    targets: [
        .target(name: "RedlineCore"),
        .testTarget(name: "RedlineCoreTests", dependencies: ["RedlineCore"]),
    ]
)
