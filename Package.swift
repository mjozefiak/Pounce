// swift-tools-version: 6.2
import PackageDescription

// Dependency graph (one way only, see AGENTS.md):
//   PounceApp -> plugins (AppsPlugin, FilesPlugin, ClipboardPlugin, DictationPlugin; MeetingsPlugin once registered) -> PouncePersistence / PounceCore -> PounceKit
//   plugins that use speech (DictationPlugin, MeetingsPlugin) -> PounceSpeech, which depends on no repository target
//   (docs/decisions/0006-shared-speech-layer.md)
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
        // PounceSpeech only. 0.x: its API stays behind the SpeechEngine port (ADR 0003). `traits: []` leaves out
        // text to speech, diarization and the bundled Rust text engine: dictation needs ASR and VAD only.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2", traits: []),
        // Whisper large-v3-turbo through Core ML (MIT), the second speech engine with a pinned language
        // (ADR 0003), used by PounceSpeech only.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
    ],
    targets: [
        // llama.cpp (MIT) as the project's own prebuilt XCFramework, pinned to a release and its checksum
        // (ADR 0005). Used by PounceSpeech only, behind the `LLMRuntime` port.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11600/llama-b11600-xcframework.zip",
            checksum: "a44f73ae282a7dc38c73107dd646d22d2463a442c7d2a36d8c9c373764759e68"
        ),
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
            // PouncePersistence only for AtomicFile (activity.json, app suggestions spec); no GRDB.
            dependencies: ["PounceKit", "PounceCore", "PouncePersistence"]
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
            name: "PounceSpeech",
            // The shared speech layer (ADR 0006): audio capture, speech to text, voice activity detection, model
            // downloads and the built-in language model. Depends on nothing from this repository
            // (`PounceSpeechTests` checks that), so every plugin may use it.
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                "llama",
            ]
        ),
        .target(
            name: "DictationPlugin",
            dependencies: [
                "PounceKit",
                "PounceCore",
                "PouncePersistence",
                "PounceSpeech",
                // The plugin owns dictation.sqlite and its migrator, like ClipboardPlugin owns clipboard.sqlite.
                .product(name: "GRDB", package: "GRDBCipher"),
            ]
        ),
        .target(
            name: "MeetingsPlugin",
            // Not registered in `PluginRegistry` yet (registration comes with the record command, spec step 1.10).
            dependencies: [
                "PounceKit",
                "PounceCore",
                "PouncePersistence",
                "PounceSpeech",
                // The plugin owns meetings.sqlite and its migrator, like ClipboardPlugin owns clipboard.sqlite.
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
            dependencies: ["AppsPlugin", "PounceKit", "PounceCore", "PouncePersistence"]
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
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "DictationPluginTests",
            dependencies: [
                "DictationPlugin", "PounceSpeech", "PounceKit", "PounceCore", "PouncePersistence",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "GRDB", package: "GRDBCipher"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MeetingsPluginTests",
            dependencies: [
                "MeetingsPlugin", "PounceSpeech", "PounceKit", "PounceCore", "PouncePersistence",
                .product(name: "GRDB", package: "GRDBCipher"),
            ]
        ),
        .testTarget(
            name: "PounceSpeechTests",
            dependencies: [
                "PounceSpeech",
                .product(name: "FluidAudio", package: "FluidAudio"),
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
