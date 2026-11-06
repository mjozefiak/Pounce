import Foundation
import LintelCore
import LintelKit
import SwiftUI

/// The history list mode's results (spec step 3.3): newest first; a query matches the first sentence fuzzily
/// and the full text through FTS5. Nothing here reads or writes `ranking.sqlite`.
struct DictationHistorySource: PanelModeSource {
    static let recentWindow = 500
    static let fullTextLimit = 200
    /// ⌃X asks first: the shell shows this with "Press ⌃X again to delete" (spec 2026-11-04, step 6.2).
    static let deleteConfirmation = ActionConfirmation(
        prompt: LocalizedStringResource(
            "Delete this dictation?", comment: "Dictation history list: asked before ⌃X deletes the entry"))

    let store: @Sendable () -> DictationStore?
    /// Pastes text into the app that was in front before the panel opened.
    let paste: @Sendable (String) async -> Void
    let delete: @Sendable (Int64) async throws -> Void
    var now: @Sendable () -> Date = { Date() }
    #if DEBUG
    /// Shows the entry in the Notes section of the main window (Notes workspace, step 3.2). DEBUG only until the
    /// Notes plugin ships (step 7.1); `nil` adds no action.
    var openInNotes: (@Sendable (Int64) async -> Void)?
    #endif

    func search(_ query: NormalizedQuery, filter: PanelModeFilter.ID?, limit: Int) async throws -> [Candidate] {
        guard let store = store() else { return [] }
        let filter = filter.flatMap(HistoryFilter.init(rawValue:))
        let now = now()
        try Task.checkCancellation()
        if query.isEmpty {
            return try store.recent(limit: limit, filter: filter).map { candidate($0, match: nil, now: now) }
        }
        var entries = try store.recent(limit: Self.recentWindow, filter: filter)
        var seen = Set(entries.map(\.id))
        let hits = try store.search(query.raw, limit: Self.fullTextLimit, filter: filter)
        for hit in hits where seen.insert(hit.id).inserted {
            entries.append(hit)
        }
        let fullText = Set(hits.map(\.id))
        try Task.checkCancellation()

        var candidates: [Candidate] = []
        for entry in entries {
            let title = DictationPresentation.title(entry)
            let match =
                FuzzyMatcher.match(query, in: TextNormalizer.prepare(title))
                ?? (fullText.contains(entry.id) ? MatchResult(tier: .fuzzy, score: 0) : nil)
            guard let match else { continue }
            candidates.append(candidate(entry, match: match, now: now))
        }
        return Array(Ranker(now: now).rank(candidates, stats: [:]).prefix(limit))
    }

    func actions(for candidate: Candidate) -> [ResultAction] {
        guard let id = DictationPresentation.entryID(candidate.itemKey) else { return [] }
        let store = store
        let paste = paste
        let delete = delete
        var actions = [
            ResultAction(
                id: "dictation.history.paste",
                title: LocalizedStringResource("Paste", comment: "Dictation history action that pastes the text"),
                symbolName: "doc.on.clipboard"
            ) { _ in
                guard let entry = try store()?.entry(id) else { return }
                await paste(entry.bestText)
            },
            ResultAction(
                id: "dictation.history.pasteRaw",
                title: LocalizedStringResource(
                    "Paste Raw", comment: "Dictation history action that pastes the raw transcript"),
                symbolName: "text.badge.minus",
                shortcut: KeyShortcut(key: "\r", modifiers: .command)
            ) { _ in
                guard let entry = try store()?.entry(id) else { return }
                await paste(entry.rawText)
            },
            ResultAction(
                id: "dictation.history.delete",
                title: LocalizedStringResource("Delete", comment: "Dictation history action that deletes the entry"),
                symbolName: "trash",
                shortcut: KeyShortcut(key: "x", modifiers: .control),
                keepsPanelOpen: true,
                confirmation: Self.deleteConfirmation
            ) { _ in try await delete(id) },
        ]
        #if DEBUG
        if let openInNotes {
            actions.append(
                ResultAction(
                    id: "dictation.history.openInLintel",
                    title: LocalizedStringResource(
                        "Open in Lintel", comment: "Dictation history action that shows the entry in the Notes section"),
                    symbolName: "arrow.up.forward.app",
                    shortcut: KeyShortcut(key: "o", modifiers: .command)
                ) { _ in await openInNotes(id) })
        }
        #endif
        return actions
    }

    private func candidate(_ entry: DictationEntry, match: MatchResult?, now: Date) -> Candidate {
        let age = max(0, now.timeIntervalSince(entry.createdAt)) / 86_400
        return Candidate(
            itemKey: DictationPresentation.itemKey(entry.id),
            title: DictationPresentation.title(entry),
            subtitle: DictationPresentation.subtitle(entry, now: now),
            icon: .symbol(entry.formattedText == nil ? "text.alignleft" : "wand.and.stars"),
            match: match ?? MatchResult(tier: .exact, score: 0),
            boost: 1 / (1 + age))
    }
}

enum DictationPresentation {
    static let pluginID: PluginID = "dictation"

    static func itemKey(_ id: Int64) -> ItemKey { ItemKey(pluginID: pluginID, key: "entry:\(id)") }

    static func entryID(_ key: ItemKey) -> Int64? {
        guard key.pluginID == pluginID, key.key.hasPrefix("entry:") else { return nil }
        return Int64(key.key.dropFirst("entry:".count))
    }

    /// The first sentence (at most 80 characters) of the text Return pastes.
    static func title(_ entry: DictationEntry) -> String {
        let text = entry.bestText.trimmingCharacters(in: .whitespacesAndNewlines)
        let flattened = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        if let end = flattened.firstIndex(where: { ".?!…".contains($0) }) {
            let sentence = String(flattened[...end])
            if sentence.count >= 8 { return String(sentence.prefix(80)) }
        }
        return String(flattened.prefix(80))
    }

    static func subtitle(_ entry: DictationEntry, now: Date) -> String {
        let when = entry.createdAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        let seconds = max(1, entry.durationMs / 1000)
        return "\(when) · \(seconds) s"
    }
}

/// The preview beside the list: the cleaned text, with a switch to the raw transcript.
struct DictationPreview: View {
    let id: Int64?
    let load: @Sendable (Int64) async -> DictationEntry?

    @State private var entry: DictationEntry?
    @State private var loadedID: Int64?
    @State private var showsRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry, entry.id == id {
                if entry.formattedText != nil {
                    Picker(selection: $showsRaw) {
                        Text("Formatted", comment: "Dictation history preview switch").tag(false)
                        Text("Raw", comment: "Dictation history preview switch").tag(true)
                    } label: {
                        Text("Version", comment: "Dictation history preview switch label")
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                ScrollView {
                    Text(shownText(entry)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                Divider()
                Text(metadata(entry)).font(.callout).foregroundStyle(.secondary)
            } else if loadedID == id, id != nil {
                Text("This entry is no longer in the history.", comment: "Dictation history preview of a deleted entry")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .padding(12)
        .task(id: id) {
            showsRaw = false
            guard let id else {
                entry = nil
                loadedID = nil
                return
            }
            let loaded = await load(id)
            guard !Task.isCancelled else { return }
            entry = loaded
            loadedID = id
        }
    }

    private func shownText(_ entry: DictationEntry) -> String {
        showsRaw ? entry.rawText : entry.bestText
    }

    private func metadata(_ entry: DictationEntry) -> String {
        var parts = [entry.createdAt.formatted(date: .abbreviated, time: .shortened)]
        parts.append("\(max(1, entry.durationMs / 1000)) s")
        if !entry.detectedLanguages.isEmpty { parts.append(entry.detectedLanguages) }
        if entry.pasteResult == .copied {
            parts.append(String(localized: "copied only", comment: "Dictation history metadata: not pasted"))
        }
        return parts.joined(separator: " · ")
    }
}

/// Above the list: why the history is not available.
struct DictationHistoryStatusView: View {
    let history: DictationHistory

    var body: some View {
        switch history.status {
        case .ready, .closed:
            if let archive = history.resetArchive {
                note(
                    String(
                        localized:
                            "The history could not be read and was started again. The old file was kept for 30 days as \(archive.lastPathComponent).",
                        comment: "Dictation history banner after a reset"))
            }
        case .unavailable:
            note(
                String(
                    localized:
                        "The history is unavailable because the Keychain could not be read. Nothing was deleted.",
                    comment: "Dictation history banner when the Keychain key is unavailable"))
        case .failed:
            note(
                String(
                    localized: "The history could not be opened.",
                    comment: "Dictation history banner when the database could not be opened"))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
    }
}
