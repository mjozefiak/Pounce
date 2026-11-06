import Foundation
import LintelKit
import Synchronization
import os

@testable import NotesPlugin

final class MemorySettings: SettingsStore {
    private let values = Mutex<[String: SettingValue]>([:])
    func value(forKey key: String) -> SettingValue? { values.withLock { $0[key] } }
    func setValue(_ value: SettingValue?, forKey key: String) { values.withLock { $0[key] = value } }
}

/// Counts every call, so a test can prove the plugin never touched the Keychain.
final class CountingKeychain: KeychainClient {
    private let counter = Mutex(0)
    var calls: Int { counter.withLock { $0 } }
    func readGenericPassword(service: String, account: String) throws(KeychainError) -> Data {
        counter.withLock { $0 += 1 }
        throw .itemNotFound
    }
    func addGenericPassword(_ data: Data, service: String, account: String) throws(KeychainError) {
        counter.withLock { $0 += 1 }
    }
    func deleteGenericPassword(service: String, account: String) throws(KeychainError) {
        counter.withLock { $0 += 1 }
    }
}

struct NoPasteboard: PasteboardClient {
    @MainActor var changeCount: Int { 0 }
    @MainActor func string() -> String? { nil }
    @MainActor func setString(_ string: String) -> Int { 0 }
}

struct NoEvents: EventPoster {
    @MainActor func postPaste() throws(EventPosterError) { throw .notPermitted }
}

struct NoWorkspace: WorkspaceClient {
    @MainActor var frontmostApplicationPID: pid_t? { nil }
    @MainActor func open(_ url: URL) async throws {}
    @MainActor func revealInFinder(_ urls: [URL]) {}
}

struct NoUsage: UsageRecorder {
    func recordUse(of key: ItemKey, queryPrefix: String?, at date: Date) async throws {}
    func stats(for keys: [ItemKey], queryPrefix: String?) async throws -> [ItemKey: UsageStats] { [:] }
}

struct NoPermissions: PermissionsReader {
    @MainActor func status(of permission: Permission) -> PermissionStatus { .notDetermined }
}

/// A context over a storage directory that is not created: a test then sees whether the plugin made it.
@MainActor
func makeContext(
    storage: URL = FileManager.default.temporaryDirectory.appending(
        path: "lintel-notes-tests-\(UUID().uuidString)", directoryHint: .isDirectory),
    settings: MemorySettings = MemorySettings(),
    keychain: any KeychainClient = CountingKeychain()
) -> PluginContext {
    PluginContext(
        storageDirectory: storage,
        settings: PluginSettings(pluginID: "notes", store: settings),
        usage: NoUsage(),
        logger: Logger(subsystem: "com.lintelapp.tests", category: "notes"),
        keychain: keychain,
        pasteboard: NoPasteboard(),
        events: NoEvents(),
        workspace: NoWorkspace(),
        permissions: NoPermissions(),
        clock: ContinuousClock()
    )
}

/// A pasteboard that remembers what was written and with which options.
final class RecordingPasteboard: PasteboardClient {
    struct Write: Sendable {
        var items: [PasteboardItem]
        var options: PasteboardWriteOptions
    }

    private let log = Mutex<[Write]>([])
    var writes: [Write] { log.withLock { $0 } }
    @MainActor var changeCount: Int { log.withLock { $0.count } }
    @MainActor func string() -> String? { nil }
    @MainActor func setString(_ string: String) -> Int { 0 }
    @MainActor func write(_ items: [PasteboardItem], options: PasteboardWriteOptions) -> Int {
        log.withLock { $0.append(Write(items: items, options: options)) }
        return log.withLock { $0.count }
    }
}

/// A save panel that answers as scripted and remembers what it was asked to write.
final class ScriptedSaver: NoteFileSaving {
    enum Answer: Sendable { case saved, cancelled, fails }
    struct Saved: Sendable, Equatable {
        var text: String
        var name: String
    }

    private let state = Mutex<(answer: Answer, saved: [Saved])>((.saved, []))
    var answer: Answer {
        get { state.withLock { $0.answer } }
        set { state.withLock { $0.answer = newValue } }
    }
    var saved: [Saved] { state.withLock { $0.saved } }

    @MainActor func save(_ text: String, suggestedName: String) async throws -> Bool {
        let answer = state.withLock { state -> Answer in
            state.saved.append(Saved(text: text, name: suggestedName))
            return state.answer
        }
        switch answer {
        case .saved: return true
        case .cancelled: return false
        case .fails: throw ScriptedError()
        }
    }
}
