// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NapariCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NapariCore", targets: ["NapariCore"]),
    ],
    targets: [
        .target(name: "NapariCore"),
        .testTarget(name: "NapariCoreTests", dependencies: ["NapariCore"]),
    ]
)
