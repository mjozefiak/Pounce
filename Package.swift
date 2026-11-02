// swift-tools-version: 6.2
import PackageDescription

// Dependency graph (one way only, see AGENTS.md):
//   PounceApp -> plugins (AppsPlugin, FilesPlugin, ClipboardPlugin, DictationPlugin) -> PouncePersistence / PounceCore -> PounceKit
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
        // Local speech to text (Parakeet) and voice activity detection through Core ML (Apache-2.0), used by
        // DictationPlugin only. 0.x: its API stays behind the SpeechEngine port (ADR 0003). `traits: []` leaves out
        // text to speech, diarization and the bundled Rust text engine: dictation needs ASR and VAD only.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2", traits: []),
        // Whisper large-v3-turbo through Core ML (MIT), the second speech engine with a pinned language
        // (ADR 0003), used by DictationPlugin only.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
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
        .target(
            name: "DictationPlugin",
            dependencies: [
                "PounceKit",
                "PounceCore",
                "PouncePersistence",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
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
                "DictationPlugin",
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
            name: "DictationPluginTests",
            dependencies: ["DictationPlugin", "PounceKit", "PounceCore", "PouncePersistence"]
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
