import AppKit
import CryptoKit
import Foundation
import LintelCore
import LintelKit
import Synchronization

/// Why a `DictationNoteSource` call could not answer. The contract says any thrown error from `list`, `exists`
/// and `content` means "unknown": the consumer never reads it as "the note is gone".
enum DictationNoteSourceError: Error, Equatable {
    /// The history is switched off, closed, unavailable (Keychain) or failed.
    case storeUnavailable
    /// The key is not `dictation:<store id>/<row id>`, or the cursor is not one this source made.
    case invalidArgument
}

/// Tells every reader of `makeChanges()` that the history changed. One stream per call, newest signal only;
/// `finishAll()` ends them all (the plugin was deactivated) and later calls start fresh streams. (Meetings has
/// its own copy: plugins never import each other.)
final class NoteChangeHub: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])

    func makeStream() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.continuations.withLock { $0.removeValue(forKey: id) }
        }
        return stream
    }

    func notify() {
        let all = continuations.withLock { Array($0.values) }
        for continuation in all { continuation.yield() }
    }

    func finishAll() {
        let all = continuations.withLock { state in
            defer { state.removeAll() }
            return Array(state.values)
        }
        for continuation in all { continuation.finish() }
    }
}

/// The dictation history as a Notes source: keys `dictation:<store id>/<row id>`, layers `cleaned` (author
/// `agent`, only when the entry has a cleaned text) and `original` (author `stt`, the raw transcript). The store
/// id (`DictationHistory.storeID`) changes whenever the Keychain item is recreated, so an erased history never
/// hands an old key to a new entry; a key of another store id is simply absent.
///
/// While the history is not open (switched off, Keychain locked or denied, failed) `list`, `exists` and
/// `content` throw, and only an open store reports a note as absent. Dictated text never reaches a log.
final class DictationNoteSource: NoteSource {
    static let maxPageSize = 200

    let pluginID: PluginID = DictationPresentation.pluginID
    private let history: DictationHistory
    private let hub: NoteChangeHub
    private let appName: @Sendable (String) -> String?
    /// Runs between the lookup of the entry and the delete on the main actor. A test seam: production passes
    /// nothing, tests close the history here to reproduce the history closing in that gap.
    private let beforeDelete: @Sendable () async -> Void

    init(
        history: DictationHistory, hub: NoteChangeHub,
        appName: @escaping @Sendable (String) -> String? = DictationNoteSource.installedAppName,
        beforeDelete: @escaping @Sendable () async -> Void = {}
    ) {
        self.history = history
        self.hub = hub
        self.appName = appName
        self.beforeDelete = beforeDelete
    }

    static func installedAppName(_ bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    /// The open store and its identity, or a throw.
    private var open: (store: DictationStore, storeID: String) {
        get throws {
            guard let store = history.storeBox.value, !store.isClosed, let id = history.storeID else {
                throw DictationNoteSourceError.storeUnavailable
            }
            return (store, id)
        }
    }

    private func rowID(of key: NoteKey, storeID: String) throws -> Int64? {
        guard key.pluginID == pluginID else { throw DictationNoteSourceError.invalidArgument }
        let parts = key.id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, let row = Int64(parts[1]) else {
            throw DictationNoteSourceError.invalidArgument
        }
        return parts[0] == storeID ? row : nil
    }

    static func key(storeID: String, row: Int64) -> NoteKey {
        NoteKey(pluginID: DictationPresentation.pluginID, id: "\(storeID)/\(row)")
    }

    // MARK: Reading

    func list(matching query: NormalizedQuery?, after: NoteCursor?, limit: Int) async throws -> NotePage {
        let (store, storeID) = try open
        let position = try after.map(Self.position(of:))
        let text = (query?.isEmpty == false) ? query?.raw : nil
        let size = min(max(1, limit), Self.maxPageSize)
        let appName = appName
        return try await Self.page(
            store: store, storeID: storeID, text: text, position: position, size: size, appName: appName)
    }

    @concurrent
    private static func page(
        store: DictationStore, storeID: String, text: String?, position: DictationStore.NotePosition?, size: Int,
        appName: @Sendable (String) -> String?
    ) async throws -> NotePage {
        try Task.checkCancellation()
        let entries = try store.noteEntries(matching: text, after: position, limit: size + 1)
        let total = try store.noteCount(matching: text)
        let shown = Array(entries.prefix(size))
        let words = text.map(WordPrefixes.words(of:)) ?? []
        let items = shown.map { entry -> NoteSummary in
            var summary = DictationNoteMapping.summary(entry, storeID: storeID, appName: appName)
            if !words.isEmpty {
                summary.matches = DictationNoteMapping.matches(entry, words: words)
            }
            return summary
        }
        let next = entries.count > size ? shown.last.map(cursor(after:)) : nil
        return NotePage(items: items, next: next, total: total)
    }

    private static func cursor(after entry: DictationEntry) -> NoteCursor {
        NoteCursor(token: "\(entry.createdAt.timeIntervalSince1970)|\(entry.id)")
    }

    private static func position(of cursor: NoteCursor) throws -> DictationStore.NotePosition {
        let parts = cursor.token.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, let created = Double(parts[0]), let id = Int64(parts[1]) else {
            throw DictationNoteSourceError.invalidArgument
        }
        return DictationStore.NotePosition(createdAt: created, id: id)
    }

    func exists(_ keys: [NoteKey]) async throws -> Set<NoteKey> {
        let (store, storeID) = try open
        // A key that is not this source's (another plugin, or not `<store id>/<row id>`) is not in the batch's
        // answer; it never fails the keys that are. The store is open here, so absence is a real answer.
        var wanted: [Int64: NoteKey] = [:]
        for key in keys {
            if let row = (try? rowID(of: key, storeID: storeID)) ?? nil { wanted[row] = key }
        }
        return try await Self.existing(store: store, wanted: wanted)
    }

    @concurrent
    private static func existing(store: DictationStore, wanted: [Int64: NoteKey]) async throws -> Set<NoteKey> {
        var found = Set<NoteKey>()
        let ids = Array(wanted.keys)
        for start in stride(from: 0, to: ids.count, by: 400) {
            try Task.checkCancellation()
            for entry in try store.entries(ids: Array(ids[start..<min(start + 400, ids.count)])) {
                if let key = wanted[entry.id] { found.insert(key) }
            }
        }
        return found
    }

    func content(for key: NoteKey) async throws -> NoteContent? {
        let (store, storeID) = try open
        guard let row = try rowID(of: key, storeID: storeID) else { return nil }
        let appName = appName
        return try await Self.content(store: store, storeID: storeID, row: row, appName: appName)
    }

    @concurrent
    private static func content(
        store: DictationStore, storeID: String, row: Int64, appName: @Sendable (String) -> String?
    ) async throws -> NoteContent? {
        try Task.checkCancellation()
        guard let entry = try store.entry(row) else { return nil }
        return NoteContent(
            summary: DictationNoteMapping.summary(entry, storeID: storeID, appName: appName),
            layers: DictationNoteMapping.layers(entry), speakers: [], details: DictationNoteMapping.details(entry))
    }

    // MARK: Deleting

    /// Deletes the entry; one that is already gone, or that belongs to an earlier store, is not an error.
    func delete(_ key: NoteKey) async throws {
        let (store, storeID) = try open
        guard let row = try rowID(of: key, storeID: storeID) else { return }
        guard try store.entry(row) != nil else { return }
        await beforeDelete()
        let history = history
        // `DictationHistory.delete` does nothing while the store is gone, which would read as success: the
        // store is checked again after the hop, where the delete itself runs.
        let source = self
        try await MainActor.run {
            _ = try source.open
            try history.delete([row])
        }
    }

    func actions(for key: NoteKey) -> [NoteSourceAction] { [] }

    func makeChanges() -> AsyncStream<Void> { hub.makeStream() }
}

/// Words of a search text, matched as prefixes of the words of a layer (like the full-text index does).
enum WordPrefixes {
    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    static func words(of query: String) -> [String] {
        normalize(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(20).map(String.init)
    }

    /// The range of the first word that matches the first typed word, when every typed word is the prefix of a
    /// word of `text`.
    static func match(in text: String, words: [String]) -> Range<String.Index>? {
        guard let first = words.first else { return nil }
        var tokens: [(String, Range<String.Index>)] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let isWord = text[index].isLetter || text[index].isNumber
            if isWord, start == nil { start = index }
            let next = text.index(after: index)
            if !isWord || next == text.endIndex, let from = start {
                let end = isWord ? next : index
                tokens.append((normalize(String(text[from..<end])), from..<end))
                start = nil
            }
            index = next
        }
        guard words.allSatisfy({ word in tokens.contains { $0.0.hasPrefix(word) } }) else { return nil }
        return tokens.first { $0.0.hasPrefix(first) }?.1
    }

    static func snippet(in text: String, around range: Range<String.Index>, radius: Int = 60) -> String {
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        let body = String(text[start..<end]).split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }
}

/// Pure rules that turn a history entry into what the Notes workspace shows.
enum DictationNoteMapping {
    static let cleanedLayerID = "cleaned"
    static let originalLayerID = "original"

    /// `none` and `ok` are ready, `partial` and `failed` as stored (dictation has no running state).
    static func state(_ status: FormatStatus) -> NoteState {
        switch status {
        case .none, .ok: .ready
        case .partial: .partial
        case .failed: .failed
        }
    }

    static func summary(_ entry: DictationEntry, storeID: String, appName: (String) -> String?) -> NoteSummary {
        let title = DictationPresentation.title(entry)
        return NoteSummary(
            id: DictationNoteSource.key(storeID: storeID, row: entry.id), kind: .dictation,
            title: title.isEmpty ? nil : title, startedAt: entry.createdAt,
            durationMs: entry.durationMs > 0 ? entry.durationMs : nil,
            sourceApp: entry.targetBundleID.flatMap(appName).flatMap { $0.isEmpty ? nil : $0 },
            state: state(entry.formatStatus))
    }

    /// The text as Markdown that renders as the same plain text: invisible characters removed, every line its own
    /// paragraph, Markdown characters escaped.
    static func markdown(_ text: String) -> String {
        MarkdownText.cleaned(text, keepNewlines: true)
            .split(whereSeparator: \.isNewline)
            .map { escape(String($0).trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private static let specials: Set<Character> = [
        "\\", "`", "*", "_", "[", "]", "(", ")", "<", ">", "#", "~", "|", "&", "!", ":", "@",
    ]

    private static func escape(_ line: String) -> String {
        var result = ""
        for character in line {
            if specials.contains(character) { result.append("\\") }
            result.append(character)
        }
        // A leading list marker or number would start a list.
        if let first = result.first, first == "-" || first == "+" { result = "\\" + result }
        if let match = result.prefixMatch(of: /\d{1,9}(?=[.)] )/) {
            result.insert("\\", at: result.index(match.range.upperBound, offsetBy: 0))
        }
        return result
    }

    static func layers(_ entry: DictationEntry) -> [NoteLayer] {
        var result: [NoteLayer] = []
        if let formatted = entry.formattedText {
            let text = markdown(formatted)
            if !text.isEmpty {
                result.append(
                    NoteLayer(id: cleanedLayerID, author: .agent, markdown: text, version: version(of: text)))
            }
        }
        let original = markdown(entry.rawText)
        if !original.isEmpty {
            result.append(
                NoteLayer(id: originalLayerID, author: .stt, markdown: original, version: version(of: original)))
        }
        return result
    }

    static func version(of markdown: String) -> String {
        SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ entry: DictationEntry, words: [String]) -> [NoteLayerMatch] {
        var result: [NoteLayerMatch] = []
        for (id, text) in [(cleanedLayerID, entry.formattedText), (originalLayerID, entry.rawText)] {
            guard let text else { continue }
            let plain = MarkdownText.cleaned(text, keepNewlines: false)
            if let range = WordPrefixes.match(in: plain, words: words) {
                result.append(NoteLayerMatch(layerID: id, snippet: WordPrefixes.snippet(in: plain, around: range)))
            }
        }
        return result
    }

    static func details(_ entry: DictationEntry) -> [NoteDetail] {
        var result: [NoteDetail] = []
        if !entry.speechModelID.isEmpty {
            result.append(
                NoteDetail(
                    label: LocalizedStringResource(
                        "Speech model", comment: "Notes details: the model that wrote the transcript"),
                    value: entry.speechModelID))
        }
        if !entry.detectedLanguages.isEmpty {
            result.append(
                NoteDetail(
                    label: LocalizedStringResource("Language", comment: "Notes details: the languages detected"),
                    value: entry.detectedLanguages))
        }
        if let model = entry.formatterModel, !model.isEmpty {
            result.append(
                NoteDetail(
                    label: LocalizedStringResource(
                        "Cleanup model", comment: "Notes details: the model that cleaned the text"),
                    value: model))
        }
        return result
    }
}
