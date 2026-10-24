// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NapariCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NapariCore", targets: ["NapariCore"]),
    ],
    dependencies: [
        // zstd is the default compressor for OME-Zarr written by ome-zarr-py.
        .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.6"),
    ],
    targets: [
        .target(name: "NapariCore", dependencies: [.product(name: "libzstd", package: "zstd")]),
        .testTarget(name: "NapariCoreTests", dependencies: ["NapariCore", .product(name: "libzstd", package: "zstd")]),
    ]
)
