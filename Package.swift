// swift-tools-version: 5.10
import PackageDescription

// macOS ships SQLite in the SDK; linking Homebrew's dylib can raise the deployment target
// and make the menu-bar bundle depend on a machine-specific installation.
#if os(macOS)
let sqlitePackageConfiguration: String? = nil
#else
let sqlitePackageConfiguration: String? = "sqlite3"
#endif

let package = Package(
    name: "WorklogAgent",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "WorklogCore", targets: ["WorklogCore"]),
        .executable(name: "WorklogAgent", targets: ["WorklogAgent"]),
        .executable(name: "WorklogMenuBar", targets: ["WorklogMenuBar"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: sqlitePackageConfiguration,
            providers: [
                .brew(["sqlite3"]),
                .apt(["libsqlite3-dev"])
            ]
        ),
        .target(
            name: "WorklogCore",
            dependencies: ["CSQLite"]
        ),
        .executableTarget(
            name: "WorklogAgent",
            dependencies: ["WorklogCore"]
        ),
        .executableTarget(
            name: "WorklogMenuBar",
            dependencies: ["WorklogCore"]
        ),
        .testTarget(
            name: "WorklogCoreTests",
            dependencies: ["WorklogCore", "CSQLite"]
        )
    ]
)
