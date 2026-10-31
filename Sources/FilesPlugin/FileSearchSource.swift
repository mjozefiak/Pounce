import Foundation
import PounceCore
import PounceKit
import os

/// Searches file and folder names in the index (spec step 3.3). Results carry the item key
/// `files:<absolute path>`, the containing folder as the subtitle (home shown as `~`) and the item's own
/// icon. An empty query returns the most used files that still exist in the index.
struct FileSearchSource: SearchSource {
    let id: SourceID = "files.names"
    let index: FileIndex
    let usage: any UsageRecorder
    let workspace: any WorkspaceClient
    let pasteboard: any PasteboardClient
    let home: String
    let clock: @Sendable () -> Date
    private let signposter = OSSignposter(subsystem: "app.pounce", category: "files")

    init(
        index: FileIndex,
        usage: any UsageRecorder,
        workspace: any WorkspaceClient,
        pasteboard: any PasteboardClient,
        home: String,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.index = index
        self.usage = usage
        self.workspace = workspace
        self.pasteboard = pasteboard
        self.home = home
        self.clock = clock
    }

    static func itemKey(_ path: String) -> ItemKey {
        ItemKey(pluginID: FilesPlugin.manifest.id, key: path)
    }

    func search(_ query: NormalizedQuery, limit: Int) async throws -> [Candidate] {
        let snapshot = index.snapshot
        guard !query.isEmpty else {
            let keys = try await usage.mostUsed(pluginID: FilesPlugin.manifest.id, limit: limit, now: clock())
            return keys.compactMap { key in
                guard let node = snapshot.locate(key.key).node, !snapshot.flags[Int(node)].contains(.root) else {
                    return nil
                }
                return candidate(
                    path: key.key, name: snapshot.name(node), kind: snapshot.kind(node),
                    match: MatchResult(tier: .exact, score: 0), boost: 0)
            }
        }
        let state = signposter.beginInterval("file query")
        defer { signposter.endInterval("file query", state) }
        let hits = try await FileSearch.search(query, in: snapshot, limit: limit, now: clock())
        return hits.map { candidate(path: $0.path, name: $0.name, kind: $0.kind, match: $0.match, boost: $0.boost) }
    }

    private func candidate(path: String, name: String, kind: EntryKind, match: MatchResult, boost: Double)
        -> Candidate
    {
        Candidate(
            itemKey: Self.itemKey(path),
            title: name,
            subtitle: PathText.abbreviate(PathText.parent(path), home: home),
            icon: .file(URL(filePath: path, directoryHint: kind == .directory ? .isDirectory : .notDirectory)),
            match: match,
            boost: boost
        )
    }

    func actions(for candidate: Candidate) -> [ResultAction] {
        guard candidate.itemKey.pluginID == FilesPlugin.manifest.id else { return [] }
        return FileActions(
            path: candidate.itemKey.key, itemKey: candidate.itemKey, usage: usage, workspace: workspace,
            pasteboard: pasteboard, clock: clock
        ).all
    }
}

/// Why a file action did not run.
enum FileActionError: Error, Equatable {
    /// The item was moved or deleted since it was indexed.
    case missing
}

/// The actions of a file result (spec: API Contracts, file actions): Return opens with the default app,
/// ⌘Return shows it in Finder, ⌘C copies the path, ⌘⇧C copies the file itself. Each use is recorded
/// in `ranking.sqlite` under `files:<path>`.
struct FileActions: Sendable {
    static let openID = "files.open"
    static let revealID = "files.reveal"
    static let copyPathID = "files.copyPath"
    static let copyFileID = "files.copyFile"

    let path: String
    let itemKey: ItemKey
    let usage: any UsageRecorder
    let workspace: any WorkspaceClient
    let pasteboard: any PasteboardClient
    let clock: @Sendable () -> Date

    var url: URL { URL(filePath: path) }

    var all: [ResultAction] { [open, reveal, copyPath, copyFile] }

    private func record(_ context: ActionContext) async throws {
        let prefix = context.query.flatMap { Ranker.queryPrefix($0.normalized) }
        try await usage.recordUse(of: itemKey, queryPrefix: prefix, at: clock())
    }

    private func requireExisting() throws {
        guard FileManager.default.fileExists(atPath: path) else { throw FileActionError.missing }
    }

    var open: ResultAction {
        let actions = self
        return ResultAction(
            id: Self.openID,
            title: LocalizedStringResource("Open", comment: "Result action that opens the selected file"),
            symbolName: "arrow.up.forward.square",
            shortcut: KeyShortcut(key: "\r")
        ) { context in
            try actions.requireExisting()
            try await actions.workspace.open(actions.url)
            try await actions.record(context)
        }
    }

    var reveal: ResultAction {
        let actions = self
        return ResultAction(
            id: Self.revealID,
            title: LocalizedStringResource("Show in Finder", comment: "Result action that reveals the item in Finder"),
            symbolName: "folder",
            shortcut: KeyShortcut(key: "\r", modifiers: .command)
        ) { context in
            try actions.requireExisting()
            await actions.workspace.revealInFinder([actions.url])
            try await actions.record(context)
        }
    }

    var copyPath: ResultAction {
        let actions = self
        return ResultAction(
            id: Self.copyPathID,
            title: LocalizedStringResource("Copy Path", comment: "Result action that copies the file's path"),
            symbolName: "doc.on.doc",
            shortcut: KeyShortcut(key: "c", modifiers: .command)
        ) { context in
            await actions.pasteboard.setString(actions.path)
            await context.panel.showConfirmation(
                LocalizedStringResource("Path Copied", comment: "Confirmation after copying a file's path"))
            try await actions.record(context)
        }
    }

    var copyFile: ResultAction {
        let actions = self
        return ResultAction(
            id: Self.copyFileID,
            title: LocalizedStringResource("Copy File", comment: "Result action that copies the file itself"),
            symbolName: "doc.on.clipboard",
            shortcut: KeyShortcut(key: "c", modifiers: [.command, .shift])
        ) { context in
            try actions.requireExisting()
            await actions.pasteboard.write([Self.pasteboardItem(for: actions.url)])
            await context.panel.showConfirmation(
                LocalizedStringResource("File Copied", comment: "Confirmation after copying a file"))
            try await actions.record(context)
        }
    }

    /// What Finder puts on the pasteboard for a copied file: its file URL, plus its name as text.
    static func pasteboardItem(for url: URL) -> PasteboardItem {
        PasteboardItem(representations: [
            PasteboardRepresentation(type: "public.file-url", data: Data(url.absoluteString.utf8)),
            PasteboardRepresentation(
                type: PasteboardRepresentation.plainTextType, data: Data(url.lastPathComponent.utf8)),
        ])
    }
}
