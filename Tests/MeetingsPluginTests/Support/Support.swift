import Foundation
import PounceKit
import PouncePersistence
import Synchronization
import Testing
import os

@testable import MeetingsPlugin

/// Settings in memory (no `UserDefaults` suite left behind).
final class MemorySettingsStore: SettingsStore {
    private let values = Mutex<[String: SettingValue]>([:])

    init(_ initial: [String: SettingValue] = [:]) {
        values.withLock { $0 = initial }
    }

    func value(forKey key: String) -> SettingValue? { values.withLock { $0[key] } }

    func setValue(_ value: SettingValue?, forKey key: String) {
        values.withLock { $0[key] = value }
    }
}

/// A temporary directory removed when the test object is released.
final class TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "pounce-meetings-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A Keychain in memory whose reads can be made to fail. Tests never touch the real one.
final class MemoryKeychain: KeychainClient {
    struct State {
        var items: [String: Data] = [:]
        var readError: KeychainError?
        var deletes = 0
    }

    let state = Mutex(State())

    var itemNames: Set<String> { state.withLock { Set($0.items.keys) } }
    var deleteCount: Int { state.withLock { $0.deletes } }

    func failReads(with error: KeychainError?) {
        state.withLock { $0.readError = error }
    }

    func readGenericPassword(service: String, account: String) throws(KeychainError) -> Data {
        let result: Result<Data, KeychainError> = state.withLock { state in
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

/// The library never reaches `ranking.sqlite`: any call fails the test through `callCount`.
final class NoUsage: UsageRecorder {
    let calls = Mutex(0)
    var callCount: Int { calls.withLock { $0 } }

    func recordUse(of key: ItemKey, queryPrefix: String?, at date: Date) async throws {
        calls.withLock { $0 += 1 }
    }

    func stats(for keys: [ItemKey], queryPrefix: String?) async throws -> [ItemKey: UsageStats] {
        calls.withLock { $0 += 1 }
        return [:]
    }

    func mostUsed(pluginID: PluginID, limit: Int, now: Date) async throws -> [ItemKey] {
        calls.withLock { $0 += 1 }
        return []
    }
}

@MainActor final class InertPasteboard: PasteboardClient {
    nonisolated init() {}
    var changeCount: Int { 0 }
    func string() -> String? { nil }
    func setString(_ string: String) -> Int { 0 }
}

@MainActor final class InertEvents: EventPoster {
    nonisolated init() {}
    func postPaste() throws(EventPosterError) {}
}

@MainActor final class InertWorkspace: WorkspaceClient {
    nonisolated init() {}
    var frontmostApplicationPID: pid_t? { nil }
    func open(_ url: URL) async throws {}
    func revealInFinder(_ urls: [URL]) {}
    var frontmostApplication: RunningApplication? { nil }
    func runningApplication(processIdentifier: pid_t) -> RunningApplication? { nil }
}

@MainActor final class GrantedPermissions: PermissionsReader {
    nonisolated init() {}
    func status(of permission: Permission) -> PermissionStatus { .granted }
}

/// Records what the retention job asks of the spool. `existing` is what is on "disk": only those uuids are
/// reported as removed.
final class RecordingSpool: SpoolMaintenance {
    struct State {
        var removedForMeetings: [String] = []
        var sweeps: [(cutoff: Date, candidates: Set<String>)] = []
        var existing: Set<String> = []
    }

    let state = Mutex(State())

    init(existing: Set<String> = []) {
        state.withLock { $0.existing = existing }
    }

    func removeSpools(forMeetings uuids: [String]) -> [String] {
        state.withLock { state in
            state.removedForMeetings += uuids
            return uuids.filter { state.existing.remove($0) != nil }
        }
    }

    func hasSpool(forMeeting uuid: String) -> Bool { state.withLock { $0.existing.contains(uuid) } }
    func spoolFolderNames() -> [String] { state.withLock { $0.existing.sorted() } }

    func removeSpools(olderThan cutoff: Date, among candidates: Set<String>) -> [String] {
        state.withLock { state in
            state.sweeps.append((cutoff, candidates))
            let removed = candidates.intersection(state.existing)
            state.existing.subtract(removed)
            return removed.sorted()
        }
    }
}

/// A plugin context wired to fakes: an in-memory keychain and settings, a temporary folder.
@MainActor
struct MeetingsHarness {
    let directory: TemporaryDirectory
    let keychain = MemoryKeychain()
    let settings: MemorySettingsStore
    let usage = NoUsage()
    let context: PluginContext

    /// `Plugins/meetings` inside the temporary folder.
    var pluginDirectory: URL { context.storageDirectory }

    init(settings initial: [String: SettingValue] = [:]) throws {
        let directory = try TemporaryDirectory()
        let settings = MemorySettingsStore(initial)
        self.directory = directory
        self.settings = settings
        context = PluginContext(
            storageDirectory: directory.url.appending(path: "Plugins/meetings", directoryHint: .isDirectory),
            settings: PluginSettings(pluginID: "meetings", store: settings),
            usage: usage,
            logger: Logger(subsystem: "app.pounce.tests", category: "meetings"),
            keychain: keychain,
            pasteboard: InertPasteboard(),
            events: InertEvents(),
            workspace: InertWorkspace(),
            permissions: GrantedPermissions(),
            clock: ContinuousClock(),
            modelsDirectory: directory.url.appending(path: "Models", directoryHint: .isDirectory)
        )
    }

    var meetingsSettings: MeetingsSettings { MeetingsSettings(context.settings) }

    func library(
        now: @escaping () -> Date = { Date() }, spool: any SpoolMaintenance = NoSpoolMaintenance()
    ) -> MeetingsLibrary {
        MeetingsLibrary(
            directory: pluginDirectory, keychain: keychain, settings: meetingsSettings, clock: ContinuousClock(),
            now: now, spool: spool, runsRetentionJob: false, logger: context.logger)
    }
}

func testKeys(_ byte: UInt8 = 9) throws -> MeetingKeys {
    try MeetingKeys(#require(MasterKeys(master: Data(repeating: byte, count: 32))))
}

/// Locations in the source tree, found by walking up from this file, so a test file can live in any folder.
enum TestPaths {
    static let repoRoot: URL = {
        var url = URL(filePath: #filePath).deletingLastPathComponent()
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }()

    static let meetingsSources = repoRoot.appending(path: "Sources/MeetingsPlugin", directoryHint: .isDirectory)

    /// Every `.swift` file under `Sources/MeetingsPlugin`, in any subfolder, sorted by name.
    static func meetingsSourceFiles() -> [URL] {
        let walker = FileManager.default.enumerator(at: meetingsSources, includingPropertiesForKeys: nil)
        var files: [URL] = []
        while let url = walker?.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The one source file called `name` (names are unique across the plugin's folders).
    static func meetingsSource(named name: String) -> URL {
        meetingsSourceFiles().first { $0.lastPathComponent == name } ?? meetingsSources.appending(path: name)
    }
}
