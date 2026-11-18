// swift-tools-version: 5.9
import PackageDescription

#if os(macOS)
// The macOS SDK supplies SQLite headers and the library directly.
let sqlitePkgConfig: String? = nil
#else
let sqlitePkgConfig: String? = "sqlite3"
#endif

let package = Package(
    name: "Notifdex",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NotifdexCore", targets: ["NotifdexCore"]),
        .executable(name: "notifdex-capture", targets: ["NotifdexCapture"]),
        .executable(name: "Notifdex", targets: ["NotifdexApp"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: sqlitePkgConfig),
        .target(name: "NotifdexCore", dependencies: ["CSQLite"], resources: [.copy("schema.sql"), .copy("rolodex.sql")]),
        .target(name: "NotifdexMac", dependencies: ["NotifdexCore"]),
        .executableTarget(name: "NotifdexCapture", dependencies: ["NotifdexCore", "NotifdexMac"]),
        .executableTarget(name: "NotifdexApp", dependencies: ["NotifdexCore", "NotifdexMac"]),
        .testTarget(name: "NotifdexCoreTests", dependencies: ["NotifdexCore", "CSQLite"]),
        .testTarget(name: "NotifdexMacTests", dependencies: ["NotifdexMac", "NotifdexCore"])
    ]
)
