import Foundation
import LintelCore
import LintelKit
import os

/// Path mode (spec: file path search): a query that starts with `/` or `~` lists that folder straight from
/// disk instead of searching the index, so folders the index skips (hidden, excluded, outside the roots)
/// still work.
///
/// - The first result is the folder itself (filter empty), then its contents: folders before files,
///   alphabetical, or matched against the filter (the text after the last `/`).
/// - The order is encoded in tiers and scores so it survives the shell's `Ranker`: the folder row is
///   `.exact` with score 1; unfiltered contents are `.prefix` with 0.6 for folders and 0.5 for the rest
///   (files, links and packages such as `.app`, which open as one item), and equal scores sort by title. Frecency may lift a used item within its tier, as everywhere.
/// - Results carry the usual `files:<path>` key and file actions; uses are recorded without a query prefix,
///   because every path query shares the same prefix (A9).
/// - A protected folder without Full Disk Access, or an unreadable one, shows only the folder row with a
///   note, so the user can still reveal it in Finder.
struct PathSearchSource: SearchSource {
    let id: SourceID = "files.path"
    let lister: DirectoryLister
    let usage: any UsageRecorder
    let workspace: any WorkspaceClient
    let pasteboard: any PasteboardClient
    let home: String
    let fullDiskAccess: @Sendable () -> Bool
    let includesHidden: @Sendable () -> Bool
    let clock: @Sendable () -> Date
    private let signposter = OSSignposter(subsystem: "com.lintelapp", category: "files")

    static let folderScore = 0.6
    static let otherScore = 0.5

    init(
        lister: DirectoryLister,
        usage: any UsageRecorder,
        workspace: any WorkspaceClient,
        pasteboard: any PasteboardClient,
        home: String,
        fullDiskAccess: @escaping @Sendable () -> Bool,
        includesHidden: @escaping @Sendable () -> Bool,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.lister = lister
        self.usage = usage
        self.workspace = workspace
        self.pasteboard = pasteboard
        self.home = home
        self.fullDiskAccess = fullDiskAccess
        self.includesHidden = includesHidden
        self.clock = clock
    }

    func search(_ query: NormalizedQuery, limit: Int) async throws -> [Candidate] {
        guard limit > 0, let path = PathQuery.parse(query.raw, home: home) else { return [] }
        let state = signposter.beginInterval("path query")
        defer { signposter.endInterval("path query", state) }
        let hasAccess = fullDiskAccess()
        let listing = try await lister.listing(path.folder, fullDiskAccess: hasAccess)
        try Task.checkCancellation()
        func candidate(_ path: String, _ kind: EntryKind, _ match: MatchResult) -> Candidate {
            self.candidate(path: path, kind: kind, match: match, fullDiskAccess: hasAccess)
        }
        func folderRow(_ folder: String, note: String?) -> Candidate {
            self.folderRow(folder, note: note, fullDiskAccess: hasAccess)
        }

        switch listing {
        case .missing:
            return []
        case .protected:
            return [folderRow(path.folder, note: Self.protectedNote)]
        case .denied:
            return [folderRow(path.folder, note: Self.deniedNote)]
        case .listed(let entries, _):
            var results: [Candidate] = []
            if path.filter.isEmpty {
                results.append(folderRow(path.folder, note: nil))
            }
            let showsHidden = includesHidden() || path.wantsHidden
            let scalars = Array(path.normalizedFilter.unicodeScalars)
            var children: [Candidate] = []
            for entry in entries where showsHidden || !entry.isHidden {
                let match: MatchResult
                if scalars.isEmpty {
                    let score = entry.kind == .directory ? Self.folderScore : Self.otherScore
                    match = MatchResult(tier: .prefix, score: score)
                } else {
                    guard let found = FuzzyMatcher.match(scalars, in: NormalizedText(entry.name)) else { continue }
                    match = found
                }
                children.append(candidate(PathText.join(path.folder, entry.name), entry.kind, match))
            }
            children.sort(by: Self.isBetter)
            results.append(contentsOf: children.prefix(max(0, limit - results.count)))
            return results
        }
    }

    static func isBetter(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.match.tier != rhs.match.tier { return lhs.match.tier < rhs.match.tier }
        if lhs.match.score != rhs.match.score { return lhs.match.score > rhs.match.score }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    static var protectedNote: String {
        String(
            localized: "Contents need Full Disk Access",
            comment: "Subtitle of a folder result whose contents Lintel may not read without Full Disk Access")
    }

    static var deniedNote: String {
        String(localized: "No access to contents", comment: "Subtitle of a folder result whose contents cannot be read")
    }

    private func folderRow(_ folder: String, note: String?, fullDiskAccess: Bool) -> Candidate {
        let base = candidate(
            path: folder, kind: .directory, match: MatchResult(tier: .exact, score: 1), fullDiskAccess: fullDiskAccess)
        guard let note else { return base }
        return Candidate(
            itemKey: base.itemKey, title: base.title,
            subtitle: [base.subtitle, note].compactMap(\.self).joined(separator: " · "),
            icon: base.icon, match: base.match, boost: base.boost)
    }

    /// A result row. A protected place without Full Disk Access gets a generic symbol instead of its own
    /// icon: loading a folder's or volume's icon may read a custom icon stored inside it, which prompts.
    private func candidate(path: String, kind: EntryKind, match: MatchResult, fullDiskAccess: Bool) -> Candidate {
        let isFolder = kind == .directory || kind == .package
        let name = path == "/" ? "/" : PathText.name(path)
        let icon: LintelKit.IconRef =
            // A link may point into a protected place, and loading its icon follows it.
            !fullDiskAccess && (kind == .symlink || TCCProtectedLocations.requiresFullDiskAccess(path, home: home))
            ? .symbol(kind == .symlink ? "arrowshape.turn.up.right" : isFolder ? "folder" : "doc")
            : .file(URL(filePath: path, directoryHint: isFolder ? .isDirectory : .notDirectory))
        return Candidate(
            itemKey: FileSearchSource.itemKey(path),
            title: name,
            subtitle: path == "/" ? nil : PathText.abbreviate(PathText.parent(path), home: home),
            icon: icon,
            match: match
        )
    }

    func actions(for candidate: Candidate) -> [ResultAction] {
        guard candidate.itemKey.pluginID == FilesPlugin.manifest.id else { return [] }
        return FileActions(
            path: candidate.itemKey.key, itemKey: candidate.itemKey, usage: usage, workspace: workspace,
            pasteboard: pasteboard, clock: clock, recordsQueryPrefix: false
        ).all
    }
}
