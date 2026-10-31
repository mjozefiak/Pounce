// swift-tools-version: 6.2
import PackageDescription

// GRDB built against SQLCipher (docs/decisions/0001-sqlite.md).
//
// `upstream/` is a git submodule pinned to an unmodified GRDB.swift release tag. GRDB documents
// SQLCipher support for SwiftPM as edits to its own Package.swift (the "GRDB+SQLCipher" comments).
// This wrapper applies exactly those edits from the outside, so the upstream sources stay untouched:
// the GRDBSQLite system library is replaced by the GRDBSQLCipher shim, GRDB links SQLCipher.swift
// (Zetetic's official binary package), and SQLITE_HAS_CODEC / SQLCipher are defined.
//
// To update: bump the submodule to a new GRDB tag, compare its Package.swift "GRDB+SQLCipher"
// comments and swift settings with the ones below, and bump the SQLCipher.swift version to at least
// the one GRDB names.
let package = Package(
    name: "GRDBCipher",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GRDB", targets: ["GRDB"])
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.20.0")
    ],
    targets: [
        .target(
            name: "GRDBSQLCipher",
            dependencies: [.product(name: "SQLCipher", package: "SQLCipher.swift")],
            path: "upstream/Sources/GRDBSQLCipher"
        ),
        .target(
            name: "GRDB",
            dependencies: [
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
                .target(name: "GRDBSQLCipher"),
            ],
            path: "upstream/GRDB",
            // The privacy manifest would create a resource bundle that a plain .app cannot locate;
            // Pounce does not ship through the App Store, so it is excluded.
            exclude: ["PrivacyInfo.xcprivacy", "Documentation.docc"],
            cSettings: [.define("SQLITE_HAS_CODEC")],
            swiftSettings: [
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_ENABLE_SNAPSHOT"),
                .define("SQLITE_HAS_CODEC"),
                .define("SQLCipher"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
