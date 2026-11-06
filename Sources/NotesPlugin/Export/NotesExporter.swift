import Foundation
import LintelCore
import LintelKit

/// "Export All Notes…" (spec "NotesPlugin"): a folder with one `.md` per document head (manual notes and overlaid
/// layers; a recorded layer without an overlay stays in its source) and `manifest.json` (schema version 1). It is
/// the rollback path of the feature, so it reads only what `notes.sqlite` holds.
///
/// Every overlay is reconciled with its source first (so a regenerate is not exported over). A `detached` row
/// without user writing and without an open comment is leftover and skipped (`NotesStore.exportRows`). Every head
/// gets only `MarkdownText.strippingBidiAndControls`. The folder is written next to the destination under a
/// temporary name and renamed into place, so a failure leaves no half-written folder.
@MainActor
struct NotesExporter {
    static let schemaVersion = 1
    nonisolated static let manifestFileName = "manifest.json"

    struct Outcome: Equatable, Sendable {
        /// Where the folder ended up (the destination, or the next free name when it existed).
        var folder: URL
        var noteCount: Int
    }

    enum Failure: Error, Equatable {
        case storeUnavailable
        case writeFailed
        /// Notes never stored anything on this Mac (no `notes.sqlite`): nothing is opened and nothing is written.
        case nothingToExport
    }

    let store: NotesStore
    /// Reconciles the overlays of one recorded note with its source (`SourceReconciler.reconcile`).
    var reconcile: @MainActor (NoteKey) async -> Void = { _ in }
    /// The title the source gives a recorded note, if it answers.
    var title: @MainActor (NoteKey) async -> String? = { _ in nil }
    var now: @Sendable () -> Date = { Date() }

    func export(to destination: URL) async throws -> Outcome {
        for key in (try? store.liveOverlayKeys()) ?? [] { await reconcile(key) }
        let plan = try await plan()
        let folder = try await Task.detached(priority: .userInitiated) {
            try Self.write(plan, to: destination)
        }.value
        return Outcome(folder: folder, noteCount: plan.files.count)
    }

    // MARK: Plan

    struct Plan: Sendable {
        var files: [(name: String, markdown: String)]
        var manifest: Data
    }

    private struct Entry: Encodable {
        struct Comment: Encodable {
            var id: Int64
            var threadID: Int64
            var author: String
            var createdAt: String
            var body: String
            var quote: String

            enum CodingKeys: String, CodingKey {
                case id, author, body, quote
                case threadID = "thread_id"
                case createdAt = "created_at"
            }
        }

        var file: String
        var docID: Int64
        var key: String
        var kind: String
        var layer: String
        var title: String?
        var createdAt: String
        var updatedAt: String
        var recordingRemoved: Bool
        var authors: [String]
        var openComments: [Comment]

        enum CodingKeys: String, CodingKey {
            case file, key, kind, layer, title, authors
            case docID = "doc_id"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case recordingRemoved = "recording_removed"
            case openComments = "open_comments"
        }
    }

    private struct Manifest: Encodable {
        var schemaVersion: Int
        var exportedAt: String
        var notes: [Entry]

        enum CodingKeys: String, CodingKey {
            case notes
            case schemaVersion = "schema_version"
            case exportedAt = "exported_at"
        }
    }

    private func plan() async throws -> Plan {
        let rows: [ExportRow]
        do { rows = try store.exportRows() } catch { throw Failure.storeUnavailable }
        let stamp = ISO8601DateFormatter()
        var sourceTitles: [NoteKey: String?] = [:]
        var names = FileNames()
        var files: [(name: String, markdown: String)] = []
        var entries: [Entry] = []
        for row in rows {
            guard let head = try? store.headRevision(of: row.docID) else { continue }
            let isManual = row.sourcePluginID == NotesStore.manualPluginID
            var title = row.titleOverride
            if !isManual, !row.isDetached {
                if sourceTitles[row.key] == nil { sourceTitles[row.key] = .some(await self.title(row.key)) }
                title = sourceTitles[row.key].flatMap { $0 }
            }
            let name = names.claim(stem: Self.stem(title: title, layer: isManual ? nil : row.layer))
            let chain = (try? store.revisions(of: row.docID)) ?? []
            let blocks = MarkdownBlocks.split(head.body)
            let attribution = LayerAttribution.overlay(
                layerAuthor: NoteAuthor(rawValue: chain.first?.author ?? NoteAuthor.human.rawValue), chain: chain,
                head: StoredBlocks.decode(head.blocksJSON))
            let comments = ((try? store.openComments(of: row.docID)) ?? []).map { comment in
                Entry.Comment(
                    id: comment.id, threadID: comment.threadID, author: comment.author,
                    createdAt: stamp.string(from: comment.createdAt),
                    body: MarkdownText.strippingBidiAndControls(comment.body),
                    quote: MarkdownText.strippingBidiAndControls(comment.quote))
            }
            files.append((name, MarkdownText.strippingBidiAndControls(head.body)))
            entries.append(
                Entry(
                    file: name, docID: row.docID, key: row.key.rawValue, kind: row.kind.rawValue, layer: row.layer,
                    title: title.map(MarkdownText.strippingBidiAndControls),
                    createdAt: stamp.string(from: row.createdAt),
                    updatedAt: stamp.string(from: row.updatedAt), recordingRemoved: row.isDetached,
                    authors: attribution.infos(blocks: blocks).map(\.author.rawValue), openComments: comments))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifest = try encoder.encode(
            Manifest(schemaVersion: Self.schemaVersion, exportedAt: stamp.string(from: now()), notes: entries))
        return Plan(files: files, manifest: manifest)
    }

    // MARK: File names

    /// `<title> - <layer>`; a manual note has no layer part. Safe as a file name (`NoteMarkdownExport.fileName`).
    static func stem(title: String?, layer: String?) -> String {
        let summary = NoteSummary(
            id: NoteKey(pluginID: "notes", id: "x"), kind: .manual, title: title,
            startedAt: Date(timeIntervalSince1970: 0))
        var stem = String(NoteMarkdownExport.fileName(summary).dropLast(3).prefix(60))
        if let layer { stem += " - " + layer }
        return stem
    }

    /// Unique names, compared without case (the volume may ignore it): a repeat gets " (2)", " (3)".
    struct FileNames {
        private var used = Set<String>()

        mutating func claim(stem: String) -> String {
            var candidate = stem
            var counter = 2
            while !used.insert((candidate + ".md").lowercased()).inserted {
                candidate = "\(stem) (\(counter))"
                counter += 1
            }
            return candidate + ".md"
        }
    }

    // MARK: Write

    /// Writes into `.<name>.export-<uuid>` next to the destination and renames it into place; an existing
    /// destination is never replaced, the next free name ("<name> 2") is used.
    nonisolated private static func write(_ plan: Plan, to destination: URL) throws -> URL {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appending(
            path: ".\(destination.lastPathComponent).export-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(
                at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for file in plan.files {
                try writeFile(Data(file.markdown.utf8), named: file.name, in: temporary)
            }
            try writeFile(plan.manifest, named: manifestFileName, in: temporary)
            var target = destination
            var counter = 2
            while fileManager.fileExists(atPath: target.path) {
                target = parent.appending(
                    path: "\(destination.lastPathComponent) \(counter)", directoryHint: .isDirectory)
                counter += 1
            }
            try fileManager.moveItem(at: temporary, to: target)
            return target
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw Failure.writeFailed
        }
    }

    nonisolated private static func writeFile(_ data: Data, named name: String, in folder: URL) throws {
        let url = folder.appending(path: name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
