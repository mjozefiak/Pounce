// swift-tools-version: 6.2
import PackageDescription

// Dependency graph (one way only, see AGENTS.md):
//   PounceApp -> plugins (none yet) -> PouncePersistence / PounceCore -> PounceKit
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
        .package(path: "Packages/GRDBCipher")
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
        .executableTarget(
            name: "PounceApp",
            dependencies: ["PounceKit", "PounceCore", "PouncePersistence"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "PounceKitTests",
            dependencies: ["PounceKit"]
        ),
        .testTarget(
            name: "PouncePersistenceTests",
            dependencies: [
                "PouncePersistence",
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
