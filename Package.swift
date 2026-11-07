// swift-tools-version: 6.2
import PackageDescription

// Dependency graph (one way only, see AGENTS.md):
//   LintelApp -> plugins (AppsPlugin, FilesPlugin, ClipboardPlugin, DictationPlugin, MeetingsPlugin, NotesPlugin) -> LintelUI / LintelPersistence / LintelCore -> LintelKit
//   LintelUI holds the shared views and brand tokens (SwiftUI and AppKit, no I/O) and imports only LintelKit and
//   LintelCore (docs/decisions/0008-main-window-and-notes-library.md, decision 8)
//   plugins that use speech (DictationPlugin, MeetingsPlugin) -> LintelSpeech, which depends on no repository target
//   (docs/decisions/0006-shared-speech-layer.md)
// Only LintelApp is MainActor by default; every other target stays nonisolated and declares
// isolation explicitly.
let package = Package(
    name: "Lintel",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Lintel", targets: ["LintelApp"])
    ],
    dependencies: [
        // GRDB built against SQLCipher (spike 0.4, docs/decisions/0001-sqlite.md).
        .package(path: "Packages/GRDBCipher"),
        // Global shortcuts and the shortcut recorder (MIT), used by LintelApp only.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", exact: "1.10.0"),
        // Local speech to text (Parakeet), voice activity detection and offline speaker diarization through
        // Core ML (Apache-2.0), used by LintelSpeech and, for diarization, by MeetingsPlugin. 0.x: its API stays
        // behind the SpeechEngine and Diarizer ports (ADR 0003, ADR 0007). `traits: ["Diarizer"]` leaves out text
        // to speech and the bundled Rust text engine (the trait is opt-out upstream, which is why Lintel names it).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2", traits: ["Diarizer"]),
        // Whisper large-v3-turbo through Core ML (MIT), the second speech engine with a pinned language
        // (ADR 0003), used by LintelSpeech only.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
    ],
    targets: [
        // llama.cpp (MIT) as the project's own prebuilt XCFramework, pinned to a release and its checksum
        // (ADR 0005). Used by LintelSpeech only, behind the `LLMRuntime` port.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11600/llama-b11600-xcframework.zip",
            checksum: "a44f73ae282a7dc38c73107dd646d22d2463a442c7d2a36d8c9c373764759e68"
        ),
        .target(name: "LintelKit"),
        .target(
            name: "LintelCore",
            dependencies: ["LintelKit"]
        ),
        .target(
            name: "LintelUI",
            // Shared views and brand tokens for LintelApp and the plugins' settings panes (ADR 0008, decision 8).
            // Never a plugin or LintelApp (`DependencyRuleTests` checks that).
            dependencies: ["LintelKit", "LintelCore"]
        ),
        .target(
            name: "LintelPersistence",
            dependencies: [
                "LintelKit",
                .product(name: "GRDB", package: "GRDBCipher"),
            ]
        ),
        .target(
            name: "AppsPlugin",
            // LintelPersistence only for AtomicFile (activity.json, app suggestions spec); no GRDB.
            dependencies: ["LintelKit", "LintelCore", "LintelPersistence", "LintelUI"]
        ),
        .target(
            name: "FilesPlugin",
            dependencies: ["LintelKit", "LintelCore", "LintelPersistence", "LintelUI"]
        ),
        .target(
            name: "ClipboardPlugin",
            dependencies: [
                "LintelKit",
                "LintelCore",
                "LintelPersistence",
                "LintelUI",
                // The plugin owns clipboard.sqlite and its migrator (spec: Migracje), so it uses GRDB
                // directly: the same SQLCipher build LintelPersistence uses (ADR 0001).
                .product(name: "GRDB", package: "GRDBCipher"),
            ]
        ),
        .target(
            name: "LintelSpeech",
            // The shared speech layer (ADR 0006): audio capture, speech to text, voice activity detection, model
            // downloads and the built-in language model. Depends on nothing from this repository
            // (`LintelSpeechTests` checks that), so every plugin may use it.
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                "llama",
            ]
        ),
        .target(
            name: "DictationPlugin",
            dependencies: [
                "LintelKit",
                "LintelCore",
                "LintelPersistence",
                "LintelSpeech",
                "LintelUI",
                // The plugin owns dictation.sqlite and its migrator, like ClipboardPlugin owns clipboard.sqlite.
                .product(name: "GRDB", package: "GRDBCipher"),
            ]
        ),
        .target(
            name: "MeetingsPlugin",
            dependencies: [
                "LintelKit",
                "LintelCore",
                "LintelPersistence",
                "LintelSpeech",
                "LintelUI",
                // `FluidDiarizer` uses the offline diarizer directly (spec: Dependencies); models load only from
                // the folder `ModelManager` owns.
                .product(name: "FluidAudio", package: "FluidAudio"),
                // The plugin owns meetings.sqlite and its migrator, like ClipboardPlugin owns clipboard.sqlite.
                .product(name: "GRDB", package: "GRDBCipher"),
            ]
        ),
        .target(
            name: "NotesPlugin",
            dependencies: [
                "LintelKit",
                "LintelCore",
                "LintelPersistence",
                "LintelSpeech",
                "LintelUI",
                // The plugin owns notes.sqlite and its migrator, like MeetingsPlugin owns meetings.sqlite
                // (spec 2026-11-04-notes-workspace, 4.0).
                .product(name: "GRDB", package: "GRDBCipher"),
            ]
        ),
        .executableTarget(
            name: "LintelApp",
            dependencies: [
                "LintelKit",
                "LintelCore",
                "LintelPersistence",
                "LintelUI",
                // The Models pane lists and removes models through `ModelManagers.shared` (spec A, R-A5).
                "LintelSpeech",
                "AppsPlugin",
                "FilesPlugin",
                "ClipboardPlugin",
                "DictationPlugin",
                "MeetingsPlugin",
                "NotesPlugin",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "LintelKitTests",
            dependencies: ["LintelKit"]
        ),
        .testTarget(
            name: "LintelUITests",
            dependencies: ["LintelUI"]
        ),
        .testTarget(
            name: "LintelCoreTests",
            dependencies: ["LintelCore", "LintelKit"]
        ),
        .testTarget(
            name: "AppsPluginTests",
            dependencies: ["AppsPlugin", "LintelKit", "LintelCore", "LintelPersistence"]
        ),
        .testTarget(
            name: "FilesPluginTests",
            dependencies: ["FilesPlugin", "LintelKit", "LintelCore", "LintelPersistence"]
        ),
        .testTarget(
            name: "ClipboardPluginTests",
            dependencies: [
                "ClipboardPlugin",
                "LintelKit",
                "LintelCore",
                "LintelPersistence",
                .product(name: "GRDB", package: "GRDBCipher"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "DictationPluginTests",
            dependencies: [
                "DictationPlugin", "LintelSpeech", "LintelKit", "LintelCore", "LintelPersistence",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "GRDB", package: "GRDBCipher"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MeetingsPluginTests",
            dependencies: [
                "MeetingsPlugin", "LintelSpeech", "LintelKit", "LintelPersistence",
                .product(name: "GRDB", package: "GRDBCipher"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "NotesPluginTests",
            dependencies: [
                "NotesPlugin", "LintelKit", "LintelCore", "LintelPersistence", "LintelSpeech", "LintelUI",
                .product(name: "GRDB", package: "GRDBCipher"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "LintelSpeechTests",
            dependencies: [
                "LintelSpeech",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(
            name: "LintelPersistenceTests",
            dependencies: [
                "LintelPersistence",
                "LintelKit",
                "LintelCore",
                .product(name: "GRDB", package: "GRDBCipher"),
            ]
        ),
        .testTarget(
            name: "LintelAppTests",
            dependencies: ["LintelApp", "LintelKit", "LintelUI", "LintelSpeech"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
