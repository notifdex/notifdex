// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Notifdex",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NotifdexCore", targets: ["NotifdexCore"]),
        .executable(name: "notifdex-capture", targets: ["NotifdexCapture"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "NotifdexCore", dependencies: ["CSQLite"], resources: [.copy("schema.sql")]),
        .executableTarget(name: "NotifdexCapture", dependencies: ["NotifdexCore"]),
        .testTarget(name: "NotifdexCoreTests", dependencies: ["NotifdexCore"])
    ]
)
