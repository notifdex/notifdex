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
        .executable(name: "notifdex-capture", targets: ["NotifdexCapture"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: sqlitePkgConfig),
        .target(name: "NotifdexCore", dependencies: ["CSQLite"], resources: [.copy("schema.sql")]),
        .executableTarget(name: "NotifdexCapture", dependencies: ["NotifdexCore"]),
        .testTarget(name: "NotifdexCoreTests", dependencies: ["NotifdexCore"])
    ]
)
