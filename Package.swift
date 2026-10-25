// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GmailGTD",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "GTDCore", targets: ["GTDCore"]),
        .executable(name: "GmailGTD", targets: ["GmailGTD"]),
        .executable(name: "gtd", targets: ["gtd"]),
    ],
    targets: [
        .target(name: "GTDCore"),
        .executableTarget(name: "GmailGTD", dependencies: ["GTDCore"]),
        .executableTarget(name: "gtd", dependencies: ["GTDCore"]),
        .testTarget(name: "GTDCoreTests", dependencies: ["GTDCore"]),
        .testTarget(name: "GmailGTDTests", dependencies: ["GmailGTD", "GTDCore"]),
    ]
)
