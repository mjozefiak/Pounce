// swift-tools-version: 6.2
import PackageDescription

// Dependency graph (one way only, see AGENTS.md):
//   PounceApp -> plugins (AppsPlugin, FilesPlugin, ClipboardPlugin) -> PouncePersistence / PounceCore -> PounceKit
// Only PounceApp is MainActor by default; every other target stays nonisolated and declares
// isolation explicitly.
let package = Package(
    name: "Pounce",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Pounce", targets: ["PounceApp"])
    ],
    dependencies: [
        // GRDB built against SQLCipher (spike 0.4, docs/decisions/0001-sqlite.md).
        .package(path: "Packages/GRDBCipher"),
        // Global shortcuts and the shortcut recorder (MIT), used by PounceApp only.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", exact: "1.10.0"),
    ],
    targets: [
        .target(name: "PounceKit"),
        .target(
            name: "PounceCore",
            dependencies: ["PounceKit"]
        ),
        .target(
            name: "PouncePersistence",
            dependencies: [
                "PounceKit",
                .product(name: "GRDB", package: "GRDBCipher"),
            ]
        ),
        .target(
            name: "AppsPlugin",
            dependencies: ["PounceKit", "PounceCore"]
        ),
        .target(
            name: "FilesPlugin",
            dependencies: ["PounceKit", "PounceCore", "PouncePersistence"]
        ),
        .target(
            name: "ClipboardPlugin",
            dependencies: [
                "PounceKit",
                "PounceCore",
                "PouncePersistence",
                // The plugin owns clipboard.sqlite and its migrator (spec: Migracje), so it uses GRDB
                // directly: the same SQLCipher build PouncePersistence uses (ADR 0001).
                .product(name: "GRDB", package: "GRDBCipher"),
            ]
        ),
        .executableTarget(
            name: "PounceApp",
            dependencies: [
                "PounceKit",
                "PounceCore",
                "PouncePersistence",
                "AppsPlugin",
                "FilesPlugin",
                "ClipboardPlugin",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "PounceKitTests",
            dependencies: ["PounceKit"]
        ),
        .testTarget(
            name: "PounceCoreTests",
            dependencies: ["PounceCore", "PounceKit"]
        ),
        .testTarget(
            name: "AppsPluginTests",
            dependencies: ["AppsPlugin", "PounceKit", "PounceCore"]
        ),
        .testTarget(
            name: "FilesPluginTests",
            dependencies: ["FilesPlugin", "PounceKit", "PounceCore", "PouncePersistence"]
        ),
        .testTarget(
            name: "ClipboardPluginTests",
            dependencies: [
                "ClipboardPlugin",
                "PounceKit",
                "PounceCore",
                "PouncePersistence",
                .product(name: "GRDB", package: "GRDBCipher"),
            ]
        ),
        .testTarget(
            name: "PouncePersistenceTests",
            dependencies: [
                "PouncePersistence",
                "PounceKit",
                "PounceCore",
                .product(name: "GRDB", package: "GRDBCipher"),
            ]
        ),
        .testTarget(
            name: "PounceAppTests",
            dependencies: ["PounceApp", "PounceKit"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
