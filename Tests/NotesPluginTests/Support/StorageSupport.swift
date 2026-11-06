import Foundation
import GRDB
import LintelKit
import LintelPersistence
import Synchronization
import Testing

@testable import NotesPlugin

/// A Keychain in memory whose reads can be made to fail. Tests never touch the real one.
final class MemoryKeychain: KeychainClient {
    struct State {
        var items: [String: Data] = [:]
        var readError: KeychainError?
        var deletes = 0
        var reads = 0
    }

    let state = Mutex(State())
    var itemNames: Set<String> { state.withLock { Set($0.items.keys) } }
    var deleteCount: Int { state.withLock { $0.deletes } }
    var readCount: Int { state.withLock { $0.reads } }

    func failReads(with error: KeychainError?) { state.withLock { $0.readError = error } }

    func readGenericPassword(service: String, account: String) throws(KeychainError) -> Data {
        let result: Result<Data, KeychainError> = state.withLock { state in
            state.reads += 1
            if let error = state.readError { return .failure(error) }
            guard let data = state.items["\(service)/\(account)"] else { return .failure(.itemNotFound) }
            return .success(data)
        }
        return try result.get()
    }

    func addGenericPassword(_ data: Data, service: String, account: String) throws(KeychainError) {
        state.withLock { $0.items["\(service)/\(account)"] = data }
    }

    func deleteGenericPassword(service: String, account: String) throws(KeychainError) {
        let found = state.withLock { state in
            state.deletes += 1
            return state.items.removeValue(forKey: "\(service)/\(account)") != nil
        }
        if !found { throw .itemNotFound }
    }
}

/// Remembers every log line, so a test can prove none holds a fixture string.
final class RecordingNotesLog: NotesLogging {
    private let lines = Mutex<[(line: String, isError: Bool)]>([])
    var all: [String] { lines.withLock { $0.map(\.line) } }
    var errors: [String] { lines.withLock { $0.filter(\.isError).map(\.line) } }
    func log(_ event: NotesLogEvent, isError: Bool) { lines.withLock { $0.append((event.line, isError)) } }
}

/// A temporary `Plugins/notes/` that is removed when the test ends.
final class NotesHarness {
    let root: URL
    let directory: URL
    let keychain = MemoryKeychain()
    let log = RecordingNotesLog()
    let settingsStore = MemorySettings()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "lintel-notes-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        directory = root.appending(path: "notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var settings: PluginSettings { PluginSettings(pluginID: "notes", store: settingsStore) }
    var notesSettings: NotesSettings { NotesSettings(settings) }

    @MainActor
    func opener(now: @escaping @Sendable () -> Date = { Date() }) -> NotesLibraryOpener {
        NotesLibraryOpener(
            directory: directory, keychain: keychain, settings: notesSettings, now: now, log: log)
    }

    /// An open store with a fresh key.
    @MainActor
    func openStore() throws -> NotesStore {
        let opener = opener()
        opener.open()
        return try #require(opener.store)
    }
}

func fileMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
}

extension NewNoteDocument {
    static func manual(
        _ id: String, body: String = "body", title: String? = nil, now: Date = Date(timeIntervalSince1970: 100)
    ) -> NewNoteDocument {
        NewNoteDocument(
            key: NoteKey(pluginID: "notes", id: id), layer: "body", kind: .manual, sourcePluginID: "notes",
            titleOverride: title, sourceState: nil, sourceStartedAtMs: nil, sourceVersionSeen: nil, author: "human",
            body: body, now: now)
    }

    static func overlay(
        _ id: String, layer: String = "notes", body: String = "body", author: String = "agent",
        startedAtMs: Int64 = 1_000, state: NoteSourceState = .present, plugin: PluginID = "meetings"
    ) -> NewNoteDocument {
        NewNoteDocument(
            key: NoteKey(pluginID: plugin, id: id), layer: layer, kind: .meeting, sourcePluginID: plugin,
            titleOverride: nil, sourceState: state, sourceStartedAtMs: startedAtMs, sourceVersionSeen: "v1",
            author: author, body: body, now: Date(timeIntervalSince1970: 100))
    }
}
