// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceMixCore",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(name: "VoiceMixCore", targets: ["VoiceMixCore"])
    ],
    targets: [
        .target(name: "VoiceMixCore")
    ]
)
