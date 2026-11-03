import Foundation
import os

/// Moves the models of the previous layout into the shared `Models/` folder (ADR 0006):
/// `Plugins/dictation/Models` → `Models/speech` and `Plugins/dictation/llm` → `Models/llm`.
///
/// One atomic `rename` per folder on the same volume, idempotent, and it never merges or deletes: when the
/// source is missing or empty there is nothing to do, and when both source and target hold something the
/// source stays untouched and is logged (the plugin uses the target). `<id>.partial` folders travel with the
/// rest because they sit inside the moved folder.
struct ModelsMigration {
    let dataRoot: URL
    var fileManager: FileManager = .default
    private let logger = Logger(subsystem: "app.pounce", category: "app")

    enum Outcome: Equatable {
        case moved
        case nothingToMove
        /// Source and target both hold files: nothing was changed.
        case conflict
        case failed
    }

    /// The pairs of (old, new) folders relative to the data root.
    static let moves: [(source: String, target: String)] = [
        ("Plugins/dictation/Models", "Models/speech"),
        ("Plugins/dictation/llm", "Models/llm"),
    ]

    @discardableResult
    func run() -> [Outcome] {
        Self.moves.map { move in
            migrate(
                from: dataRoot.appending(path: move.source, directoryHint: .isDirectory),
                to: dataRoot.appending(path: move.target, directoryHint: .isDirectory))
        }
    }

    func migrate(from source: URL, to target: URL) -> Outcome {
        guard hasContents(source) else { return .nothingToMove }
        if hasContents(target) {
            logger.notice(
                "Models migration skipped: \(source.lastPathComponent, privacy: .public) and the target both exist")
            return .conflict
        }
        do {
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            // An empty target folder (created by the host) is replaced by the rename.
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            try fileManager.moveItem(at: source, to: target)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
            return .moved
        } catch {
            logger.error("Models migration failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    private func hasContents(_ directory: URL) -> Bool {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return false }
        return !names.isEmpty
    }
}
