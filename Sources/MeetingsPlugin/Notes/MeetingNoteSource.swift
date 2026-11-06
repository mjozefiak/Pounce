import Foundation
import LintelCore
import LintelKit
import Synchronization

/// Why a `MeetingNoteSource` call could not answer. The contract says any thrown error from `list`, `exists`
/// and `content` means "unknown": the consumer never reads it as "the note is gone".
enum MeetingNoteSourceError: Error, Equatable {
    /// The library is closed, unavailable (Keychain), failed or the plugin is switched off.
    case storeUnavailable
    /// The key is not `meetings:<uuid>` of a meeting, or the cursor is not one this source made.
    case invalidArgument
    /// The meeting or speaker is not there.
    case notFound
    /// The meeting is being recorded or processed.
    case active
    /// The action cannot run now.
    case unavailable
}

/// Tells every reader of `makeChanges()` that something in the library changed. One stream per call, newest
/// signal only; `finishAll()` ends them all (the plugin was deactivated) and later calls start fresh streams.
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

/// The meetings library as a Notes source: keys `meetings:<uuid>`, layers `notes` and `transcript`. Reads
/// follow the open store; while it is not open (plugin off, Keychain locked or denied, failed, not yet opened)
/// `list`, `exists` and `content` throw, and only an open store reports a meeting as absent.
///
/// Nothing here logs a title, note or transcript text, and nothing touches `ranking.sqlite`.
final class MeetingNoteSource: NoteSource {
    /// The most rows of one page.
    static let maxPageSize = 200

    let pluginID: PluginID = MeetingLibraryPresentation.pluginID
    private let library: MeetingsLibrary
    private let board: NotesBoard?
    private let hub: NoteChangeHub
    private let regenerate: (@MainActor @Sendable (Int64) -> Void)?
    private let openNotesModel: @MainActor @Sendable () -> Void
    private let appName: @Sendable (String) -> String?
    private let changed: @Sendable () -> Void

    init(
        library: MeetingsLibrary, board: NotesBoard?, hub: NoteChangeHub,
        regenerate: (@MainActor @Sendable (Int64) -> Void)?, openNotesModel: @escaping @MainActor @Sendable () -> Void,
        appName: @escaping @Sendable (String) -> String? = MeetingLibraryPresentation.installedAppName,
        changed: @escaping @Sendable () -> Void = {}
    ) {
        self.library = library
        self.board = board
        self.hub = hub
        self.regenerate = regenerate
        self.openNotesModel = openNotesModel
        self.appName = appName
        self.changed = changed
    }

    private var openStore: MeetingsStore {
        get throws {
            guard let store = library.storeBox.withLock({ $0 }) else { throw MeetingNoteSourceError.storeUnavailable }
            return store
        }
    }

    /// The uuid in a `meetings:` key.
    private func uuid(of key: NoteKey) throws -> String {
        guard key.pluginID == pluginID, !key.id.isEmpty else { throw MeetingNoteSourceError.invalidArgument }
        return key.id
    }

    // MARK: Reading

    func list(matching query: NormalizedQuery?, after: NoteCursor?, limit: Int) async throws -> NotePage {
        let store = try openStore
        let position = try after.map(Self.position(of:))
        let text = (query?.isEmpty == false) ? query?.raw : nil
        let size = min(max(1, limit), Self.maxPageSize)
        let board = board
        let appName = appName
        return try await Self.page(
            store: store, text: text, position: position, size: size, board: board, appName: appName)
    }

    @concurrent
    private static func page(
        store: MeetingsStore, text: String?, position: MeetingsStore.LibraryPosition?, size: Int,
        board: NotesBoard?, appName: @Sendable (String) -> String?
    ) async throws -> NotePage {
        try Task.checkCancellation()
        // One more than asked tells whether there is a next page.
        let entries = try store.libraryEntries(matching: text, filter: .all, limit: size + 1, after: position)
        let total = try store.libraryCount(matching: text, filter: .all)
        try Task.checkCancellation()
        let shown = Array(entries.prefix(size))
        let words = text.map(MeetingMatchLocator.words(of:)) ?? []
        var items: [NoteSummary] = []
        for entry in shown {
            var summary = MeetingNoteMapping.summary(entry, board: board, appName: appName)
            if !words.isEmpty, let document = try store.loadDocument(id: entry.id) {
                let found = MeetingMatchLocator.matches(for: document, words: words)
                summary.matches = found.layers
                summary.titleMatched = found.title
            }
            items.append(summary)
        }
        let next = entries.count > size ? shown.last.map(cursor(after:)) : nil
        return NotePage(items: items, next: next, total: total)
    }

    private static func cursor(after entry: MeetingLibraryEntry) -> NoteCursor {
        NoteCursor(token: "\(entry.startedAt.timeIntervalSince1970)|\(entry.id)")
    }

    private static func position(of cursor: NoteCursor) throws -> MeetingsStore.LibraryPosition {
        let parts = cursor.token.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, let startedAt = Double(parts[0]), let id = Int64(parts[1]) else {
            throw MeetingNoteSourceError.invalidArgument
        }
        return MeetingsStore.LibraryPosition(startedAt: startedAt, id: id)
    }

    func exists(_ keys: [NoteKey]) async throws -> Set<NoteKey> {
        let store = try openStore
        // A key that is not this source's (another plugin, or an empty id) is not in the answer; it never fails
        // the keys that are. The store is open here, so absence is a real answer.
        let wanted = keys.compactMap { try? uuid(of: $0) }
        return try await Self.existing(store: store, uuids: wanted, pluginID: pluginID)
    }

    @concurrent
    private static func existing(store: MeetingsStore, uuids: [String], pluginID: PluginID) async throws
        -> Set<NoteKey>
    {
        var found = Set<NoteKey>()
        // SQLite's variable limit is 32 766 in recent versions; stay far below.
        for start in stride(from: 0, to: uuids.count, by: 400) {
            try Task.checkCancellation()
            for entry in try store.libraryEntries(uuids: Array(uuids[start..<min(start + 400, uuids.count)])) {
                found.insert(NoteKey(pluginID: pluginID, id: entry.uuid))
            }
        }
        return found
    }

    func content(for key: NoteKey) async throws -> NoteContent? {
        let store = try openStore
        let uuid = try uuid(of: key)
        let board = board
        let appName = appName
        return try await Self.content(store: store, uuid: uuid, board: board, appName: appName)
    }

    @concurrent
    private static func content(
        store: MeetingsStore, uuid: String, board: NotesBoard?, appName: @Sendable (String) -> String?
    ) async throws -> NoteContent? {
        try Task.checkCancellation()
        guard let document = try store.loadDocument(uuid: uuid),
            let entry = try store.libraryEntry(uuid: uuid)
        else { return nil }
        try Task.checkCancellation()
        return NoteContent(
            summary: MeetingNoteMapping.summary(entry, board: board, appName: appName),
            layers: MeetingNoteLayers.layers(document), speakers: MeetingNoteLayers.speakers(document),
            details: MeetingNoteMapping.details(document))
    }

    // MARK: Deleting

    /// Deletes the meeting with its audio. A meeting being recorded or processed is refused (`active`); one
    /// that is already gone is not an error.
    func delete(_ key: NoteKey) async throws {
        let store = try openStore
        let uuid = try uuid(of: key)
        guard let id = try store.meetingID(uuid: uuid) else { return }
        let protected = await MainActor.run { library.protectedMeetingIDs }
        if protected.contains(id) { throw MeetingNoteSourceError.active }
        let spool = library.spoolStorage
        do {
            try await Task.detached { try store.deleteMeeting(id, spool: spool) }.value
        } catch MeetingActionError.active {
            throw MeetingNoteSourceError.active
        }
        await MainActor.run { library.refreshCount() }
        changed()
    }

    // MARK: Actions

    func actions(for key: NoteKey) -> [NoteSourceAction] {
        guard let uuid = try? uuid(of: key), let store = try? openStore,
            let entry = try? store.libraryEntry(uuid: uuid)
        else { return [] }
        let id = entry.id
        let library = library
        var result: [NoteSourceAction] = []
        if entry.status == .incomplete, entry.audioSpooled {
            result.append(
                NoteSourceAction(
                    id: "meetings.finish",
                    title: LocalizedStringResource("Finish", comment: "Notes: finish an interrupted transcript"),
                    symbolName: "checkmark.circle"
                ) {
                    guard let handle = await MainActor.run(body: { library.finish(meetingID: id) }) else {
                        throw MeetingNoteSourceError.unavailable
                    }
                    for await _ in handle.events {}
                    switch await handle.outcome {
                    case .unavailable, .databaseUnwritable, .failed, .notResumable:
                        throw MeetingNoteSourceError.unavailable
                    default: break
                    }
                })
        }
        let snapshot = board?.snapshot
        if let regenerate, entry.status == .ready, entry.notesStatus != .running, snapshot?.phases[id] == nil {
            result.append(
                NoteSourceAction(
                    id: "meetings.regenerate",
                    title: LocalizedStringResource(
                        "Regenerate Notes", comment: "Meeting window button"),
                    symbolName: "arrow.triangle.2.circlepath"
                ) { await MainActor.run { regenerate(id) } })
        }
        if snapshot?.needsModel(for: id) == true {
            let openNotesModel = openNotesModel
            result.append(
                NoteSourceAction(
                    id: "meetings.notesModel",
                    title: LocalizedStringResource(
                        "Download Notes Model", comment: "Meeting library action that opens the notes model settings"),
                    symbolName: "arrow.down.circle"
                ) { await MainActor.run { openNotesModel() } })
        }
        return result
    }

    func makeChanges() -> AsyncStream<Void> { hub.makeStream() }
}

extension MeetingNoteSource: NoteSourceEditing {
    private func meeting(_ key: NoteKey) throws -> (store: MeetingsStore, id: Int64) {
        let store = try openStore
        guard let id = try store.meetingID(uuid: try uuid(of: key)) else { throw MeetingNoteSourceError.notFound }
        return (store, id)
    }

    private func speakerID(_ text: String) throws -> Int64 {
        guard let id = Int64(text) else { throw MeetingNoteSourceError.notFound }
        return id
    }

    func renameTitle(_ key: NoteKey, to title: String) async throws {
        let (store, id) = try meeting(key)
        try await Task.detached { try MeetingEdits.renameTitle(id, to: title, in: store) }.value
        changed()
    }

    func renameSpeaker(_ key: NoteKey, speakerID: String, to name: String) async throws {
        let (store, id) = try meeting(key)
        let speaker = try self.speakerID(speakerID)
        try await Task.detached { try MeetingEdits.renameSpeaker(speaker, of: id, to: name, in: store) }.value
        changed()
    }

    func markSelf(_ key: NoteKey, speakerID: String) async throws {
        let (store, id) = try meeting(key)
        let speaker = try self.speakerID(speakerID)
        try await Task.detached { try MeetingEdits.markSelf(speaker, of: id, in: store) }.value
        changed()
    }
}
