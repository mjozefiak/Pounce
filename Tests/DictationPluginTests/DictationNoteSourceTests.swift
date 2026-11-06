import Foundation
import LintelKit
import Synchronization
import Testing
import os

@testable import DictationPlugin

final class SeenKeys: Sendable {
    private let state: Mutex<[NoteKey]>
    init(_ value: [NoteKey]) { state = Mutex(value) }
    func get() -> [NoteKey] { state.withLock { $0 } }
    func update(_ change: (inout [NoteKey]) -> Void) { state.withLock { change(&$0) } }
}

private func query(_ text: String) -> NormalizedQuery {
    NormalizedQuery(raw: text, normalized: text.lowercased())
}

private func entry(
    _ raw: String, formatted: String? = nil, at seconds: TimeInterval, status: FormatStatus? = nil
) -> DictationEntry {
    DictationEntry(
        createdAt: Date(timeIntervalSince1970: seconds), durationMs: 4_000, rawText: raw, formattedText: formatted,
        formatMode: formatted == nil ? .raw : .clean, formatStatus: status ?? (formatted == nil ? .none : .ok),
        detectedLanguages: "pl", speechModelID: "parakeet-ultra", formatterModel: nil, targetBundleID: nil,
        pasteResult: .pasted)
}

/// A history in a temporary folder and an in-memory Keychain, read through the Notes source.
@MainActor
struct DictationNoteRig {
    let directory: TemporaryDirectory
    let keychain = MemoryKeychain()
    let settings: DictationSettings
    let history: DictationHistory
    let hub = NoteChangeHub()
    let source: DictationNoteSource

    init(historyEnabled: Bool = true) throws {
        directory = try TemporaryDirectory()
        let store = MemorySettingsStore(["plugins.dictation.historyEnabled": .bool(historyEnabled)])
        settings = DictationSettings(PluginSettings(pluginID: "dictation", store: store))
        history = DictationHistory(
            directory: directory.url, keychain: keychain, settings: settings, clock: ContinuousClock(),
            runsRetentionJob: false, logger: Logger(subsystem: "com.lintelapp.tests", category: "dictation"))
        source = DictationNoteSource(history: history, hub: hub, appName: { _ in nil })
    }

    var store: DictationStore {
        get throws { try #require(history.storeBox.value) }
    }

    @discardableResult
    func add(_ entry: DictationEntry) throws -> NoteKey {
        let id = try store.insert(entry)
        return DictationNoteSource.key(storeID: try #require(history.storeID), row: id)
    }
}

@MainActor
@Suite("DictationNoteSource")
struct DictationNoteSourceTests {
    @Test("list is newest first with the total, pages by cursor, and keys are dictation:<store id>/<row id>")
    func listing() async throws {
        let rig = try DictationNoteRig()
        rig.history.open()
        for index in 1...5 { try rig.add(entry("wpis numer \(index)", at: Double(index) * 100)) }
        let first = try await rig.source.list(matching: nil, after: nil, limit: 2)
        #expect(first.total == 5)
        let second = try await rig.source.list(matching: nil, after: try #require(first.next), limit: 2)
        let secondNext = try #require(second.next)
        let third = try await rig.source.list(matching: nil, after: secondNext, limit: 2)
        #expect(third.next == nil)
        let all = first.items + second.items + third.items
        #expect(all.map(\.startedAt.timeIntervalSince1970) == [500, 400, 300, 200, 100])
        #expect(Set(all.map(\.id)).count == 5)
        let storeID = try #require(rig.history.storeID)
        #expect(all[0].id.rawValue.hasPrefix("dictation:\(storeID)/"))
        #expect(all.allSatisfy { $0.kind == .dictation && $0.state == .ready && $0.durationMs == 4_000 })
        await #expect(throws: DictationNoteSourceError.invalidArgument) {
            _ = try await rig.source.list(matching: nil, after: NoteCursor(token: "bad"), limit: 2)
        }
    }

    @Test("a query matches the raw and the cleaned text and reports the layers")
    func searching() async throws {
        let rig = try DictationNoteRig()
        rig.history.open()
        try rig.add(entry("pierwsze dyktowanie o budżecie", formatted: "Pierwsze dyktowanie o budżecie.", at: 100))
        try rig.add(entry("zupełnie inny temat", at: 200))
        let page = try await rig.source.list(matching: query("budzec"), after: nil, limit: 10)
        #expect(page.items.count == 1)
        #expect(page.total == 1)
        #expect(Set(page.items[0].matches.map(\.layerID)) == ["cleaned", "original"])
        #expect(page.items[0].matches.allSatisfy { $0.snippet.contains("budżecie") })
        #expect(try await rig.source.list(matching: query("%%%"), after: nil, limit: 10).items.isEmpty)
    }

    @Test("content has cleaned (agent) and original (stt) layers; a raw entry only has original")
    func layers() async throws {
        let rig = try DictationNoteRig()
        rig.history.open()
        let cleaned = try rig.add(entry("raw one", formatted: "Clean one.", at: 100))
        let raw = try rig.add(entry("only raw", at: 200))
        let content = try #require(try await rig.source.content(for: cleaned))
        #expect(content.layers.map(\.id) == ["cleaned", "original"])
        #expect(content.layers.map(\.author) == [.agent, .stt])
        #expect(
            content.layers.map(\.markdown) == ["Clean one\\.".replacingOccurrences(of: "\\.", with: "."), "raw one"])
        #expect(content.layers[0].version != content.layers[1].version)
        #expect(content.speakers.isEmpty)
        let only = try #require(try await rig.source.content(for: raw))
        #expect(only.layers.map(\.id) == ["original"])
    }

    @Test("Markdown characters and invisible text are escaped or removed so the text shows as typed")
    func escaping() throws {
        #expect(DictationNoteMapping.markdown("# not a heading") == "\\# not a heading")
        #expect(DictationNoteMapping.markdown("- not a list") == "\\- not a list")
        #expect(DictationNoteMapping.markdown("1. not a list") == "1\\. not a list")
        #expect(DictationNoteMapping.markdown("`code` and [link](http://x)").contains("\\`code\\`"))
        #expect(DictationNoteMapping.markdown("a\u{200B}b") == "ab")
        #expect(DictationNoteMapping.markdown("one\ntwo") == "one\n\ntwo")
        #expect(DictationNoteMapping.markdown("  \n ") == "")
    }

    @Test("format status maps: none and ok ready, partial partial, failed failed")
    func stateMapping() async throws {
        let rig = try DictationNoteRig()
        rig.history.open()
        let cases: [(FormatStatus, NoteState)] = [
            (.none, .ready), (.ok, .ready), (.partial, .partial), (.failed, .failed),
        ]
        for (status, expected) in cases {
            let key = try rig.add(entry("t", formatted: status == .none ? nil : "T", at: 1, status: status))
            #expect(try await rig.source.content(for: key)?.summary.state == expected)
        }
    }

    @Test("exists answers a batch; a missing row, a key of another store and a deleted entry are absent")
    func existence() async throws {
        let rig = try DictationNoteRig()
        rig.history.open()
        let kept = try rig.add(entry("a", at: 1))
        let removed = try rig.add(entry("b", at: 2))
        try await rig.source.delete(removed)
        let storeID = try #require(rig.history.storeID)
        let missing = DictationNoteSource.key(storeID: storeID, row: 999)
        let foreign = DictationNoteSource.key(storeID: "0000000000000000", row: 1)
        #expect(try await rig.source.exists([kept, removed, missing, foreign]) == [kept])
        #expect(try await rig.source.content(for: removed) == nil)
        #expect(try await rig.source.content(for: foreign) == nil)
        try await rig.source.delete(removed)  // idempotent
        try await rig.source.delete(foreign)  // belongs to an earlier store: nothing to delete
        // A malformed key or a key of another plugin in the batch does not fail the others.
        let malformed = NoteKey(pluginID: "dictation", id: "nonsense")
        let other = NoteKey(pluginID: "meetings", id: "\(storeID)/1")
        #expect(try await rig.source.exists([malformed, kept, other]) == [kept])
        #expect(try await rig.source.exists([malformed, other]).isEmpty)
    }

    @Test("the store id is stable across launches and changes after Erase Data")
    func identity() async throws {
        let rig = try DictationNoteRig()
        rig.history.open()
        let first = try #require(rig.history.storeID)
        #expect(first.count == 16)
        #expect(first.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        let key = try rig.add(entry("kept", at: 1))
        rig.history.close()
        #expect(rig.history.storeID == nil)
        // A new launch: the same Keychain item, the same folder.
        let relaunched = DictationHistory(
            directory: rig.directory.url, keychain: rig.keychain, settings: rig.settings, clock: ContinuousClock(),
            runsRetentionJob: false, logger: Logger(subsystem: "com.lintelapp.tests", category: "dictation"))
        relaunched.open()
        #expect(relaunched.storeID == first)
        let source = DictationNoteSource(history: relaunched, hub: rig.hub, appName: { _ in nil })
        #expect(try await source.exists([key]) == [key])
        // Erase Data: the Keychain item and the folder go; the next open has a new key and a new identity.
        try relaunched.erase()
        try FileManager.default.removeItem(at: rig.directory.url.appending(path: DictationStore.fileName))
        relaunched.open()
        let second = try #require(relaunched.storeID)
        #expect(second != first)
        let reused = try relaunched.store?.insert(entry("new", at: 2))
        #expect(reused == 1)  // the row id starts over, the key does not repeat
        let newKey = DictationNoteSource.key(storeID: second, row: 1)
        #expect(newKey != key)
        #expect(try await source.exists([key, newKey]) == [newKey])
        #expect(try await source.content(for: key) == nil)
    }

    @Test("history switched off and a locked Keychain each throw from every read, and nothing is deleted")
    func unavailable() async throws {
        let key = NoteKey(pluginID: "dictation", id: "abcd/1")
        let off = try DictationNoteRig(historyEnabled: false)
        off.history.open()
        await #expect(throws: DictationNoteSourceError.storeUnavailable) { _ = try await off.source.exists([key]) }
        await #expect(throws: DictationNoteSourceError.storeUnavailable) { _ = try await off.source.content(for: key) }
        await #expect(throws: DictationNoteSourceError.storeUnavailable) {
            _ = try await off.source.list(matching: nil, after: nil, limit: 5)
        }

        let locked = try DictationNoteRig()
        locked.history.open()
        let stored = try locked.add(entry("secret", at: 1))
        locked.history.close()
        locked.keychain.state.withLock { $0.readError = .interactionNotAllowed }
        locked.history.open()
        #expect(locked.history.status != .ready)
        await #expect(throws: DictationNoteSourceError.storeUnavailable) {
            _ = try await locked.source.exists([stored])
        }
        await #expect(throws: DictationNoteSourceError.storeUnavailable) {
            _ = try await locked.source.content(for: stored)
        }
        // Nothing was deleted: the key and the file are still there.
        #expect(!locked.keychain.itemNames.isEmpty)
        #expect(
            FileManager.default.fileExists(atPath: locked.directory.url.appending(path: DictationStore.fileName).path))
    }

    @Test("delete removes the entry, signals the change streams and refreshes the count")
    func deleting() async throws {
        let rig = try DictationNoteRig()
        rig.history.open()
        let key = try rig.add(entry("x", at: 1))
        rig.history.refreshCount()
        #expect(rig.history.entryCount == 1)
        try await rig.source.delete(key)
        #expect(rig.history.entryCount == 0)
        #expect(try await rig.source.content(for: key) == nil)
        #expect(rig.source.actions(for: key).isEmpty)
    }

    @Test("the plugin hands the source out and its change streams end on deactivate")
    func plugin() async throws {
        let harness = try DictationHarness(keychain: MemoryKeychain())
        let context = harness.context
        let plugin = DictationPlugin(context: context)
        let source = try #require(plugin.noteSources.first)
        #expect(source.pluginID == "dictation")
        await #expect(throws: (any Error).self) { _ = try await source.exists([]) }  // not active yet
        var iterator = source.makeChanges().makeAsyncIterator()
        await plugin.deactivate()
        #expect(await iterator.next() == nil)
    }
}

@MainActor
@Suite("DictationNoteSource: privacy")
struct DictationNotePrivacyTests {
    @Test("the source never logs or prints")
    func noLogging() throws {
        var url = URL(filePath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        let text = try String(
            contentsOf: url.appending(path: "Sources/DictationPlugin/DictationNoteSource.swift"), encoding: .utf8)
        for forbidden in ["Logger", "logger", "print(", "NSLog", "os_log", "debugPrint", "dump("] {
            #expect(!text.contains(forbidden), "uses \(forbidden)")
        }
    }
}

@MainActor
@Suite("DictationPlugin: openNote")
struct DictationOpenNoteTests {
    private func plugin(handler: @escaping @MainActor @Sendable (NoteKey) -> Bool) throws -> DictationPlugin {
        let harness = try DictationHarness(keychain: MemoryKeychain())
        let base = harness.context
        let context = PluginContext(
            storageDirectory: base.storageDirectory, settings: base.settings, usage: base.usage, logger: base.logger,
            keychain: base.keychain, pasteboard: base.pasteboard, events: base.events, workspace: base.workspace,
            permissions: base.permissions, clock: base.clock, modelsDirectory: base.modelsDirectory,
            openNote: handler)
        return DictationPlugin(context: context)
    }

    @Test("with the default handler (false) the entry is not taken, and a closed history takes nothing")
    func declined() async throws {
        let seen = SeenKeys([])
        let plugin = try plugin { key in
            seen.update { $0.append(key) }
            return false
        }
        #expect(!plugin.openNote(entryID: 1))  // history not open: no store id, no key
        #expect(seen.get().isEmpty)
        plugin.history.open()
        #expect(!plugin.openNote(entryID: 1))
        #expect(seen.get().count == 1)
    }

    @Test("a handler that returns true gets dictation:<store id>/<row id>")
    func accepted() async throws {
        let seen = SeenKeys([])
        let plugin = try plugin { key in
            seen.update { $0.append(key) }
            return true
        }
        plugin.history.open()
        let storeID = try #require(plugin.history.storeID)
        #expect(plugin.openNote(entryID: 7))
        #expect(seen.get().map(\.rawValue) == ["dictation:\(storeID)/7"])
    }
}
