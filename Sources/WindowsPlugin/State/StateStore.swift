import Foundation
import LintelKit
import LintelPersistence
import os

/// Owner of `Plugins/windows/state.json`: workspace membership and the journal of parked windows.
///
/// The `hidden` journal is the one part that is written through (write, fsync, rename, fsync of the folder)
/// before a window is parked and after every change to it; `addHidden` throws when the write fails, and the
/// caller then does not park. Membership is written deferred (`saveDelay` after the last change) and by
/// `flush()` / `close()`. A file that does not decode is moved to one `state.json.corrupt` copy and the store
/// starts empty; a file from a newer version makes the store read-only (nothing is written, so nothing may be
/// parked: `canJournal` is false); a file that cannot be read blocks writes for the session the same way and is
/// never replaced. Errors are logged without window titles or bundle ids.
actor StateStore {
    static let fileName = "state.json"
    static let corruptFileName = "state.json.corrupt"
    static let version = StateFile.currentVersion
    static let saveDelay: Duration = .seconds(5)
    /// A stored process start time matches the live one within this many seconds.
    static let processStartTolerance: Double = 1.0

    enum StoreError: Error, Equatable {
        /// The file comes from a newer version or could not be read: this session writes nothing.
        case readOnly
        case write
        /// `close()` was called and `load()` has not reopened the store: nothing is written.
        case closed
    }

    nonisolated let fileURL: URL
    nonisolated var corruptURL: URL { fileURL.deletingLastPathComponent().appending(path: Self.corruptFileName) }
    private let clock: any Clock<Duration>
    private let logger: Logger
    private let saveDelay: Duration
    private(set) var state = WindowsState.empty
    /// The file was written by a newer version, or exists but could not be read.
    private(set) var isReadOnly = false
    private var isDirty = false
    /// Set by `close()`, cleared by `load()`.
    private var isClosed = false
    private var saveTask: Task<Void, Never>?
    private var saveGeneration = 0

    init(
        directory: URL,
        clock: any Clock<Duration> = ContinuousClock(),
        saveDelay: Duration = StateStore.saveDelay,
        logger: Logger = Logger(subsystem: "com.lintelapp", category: "windows")
    ) {
        self.fileURL = directory.appending(path: Self.fileName)
        self.clock = clock
        self.saveDelay = saveDelay
        self.logger = logger
    }

    /// Whether a window may be parked: only when the journal can be written.
    var canJournal: Bool { !isReadOnly }

    // MARK: Loading

    /// Reads the file. A missing file starts empty, a corrupt one is set aside, a newer one makes the store
    /// read-only.
    func load() {
        isClosed = false
        isReadOnly = false
        isDirty = false
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            state = .empty
            if (error as NSError).code != NSFileReadNoSuchFileError {
                logger.error("Cannot read state.json: \(String(describing: error), privacy: .private)")
                isReadOnly = true
            }
            return
        }
        switch Self.decode(data) {
        case .current(let file):
            state = file.state
        case .newer:
            logger.notice("state.json comes from a newer version; window management state is read-only")
            state = Self.readOnlyState(data)
            isReadOnly = true
        case .corrupt:
            logger.error("state.json is corrupt; starting from the live windows")
            setAsideCorruptFile()
            state = .empty
        }
    }

    enum Decoded {
        case current(StateFile)
        case newer
        case corrupt
    }

    /// A file counts as current only when it is version 1 and has its fields; a larger integer `version` is a
    /// newer file whatever else it holds.
    static func decode(_ data: Data) -> Decoded {
        struct Header: Decodable { var version: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.version >= 1 else {
            return .corrupt
        }
        if header.version > version { return .newer }
        guard let file = try? JSONDecoder().decode(StateFile.self, from: data) else { return .corrupt }
        return .current(file)
    }

    /// What can still be read of a newer file, so the journal of parked windows is not lost to a downgrade:
    /// the hidden list when it decodes with the current shape, else nothing.
    private static func readOnlyState(_ data: Data) -> WindowsState {
        struct Partial: Decodable {
            var workspaces: [String: StateFile.WorkspaceRecord]?
            var hidden: [HiddenEntry]?
        }
        guard let partial = try? JSONDecoder().decode(Partial.self, from: data) else { return .empty }
        return StateFile(
            version: version,
            state: WindowsState(order: [:], hidden: partial.hidden ?? [])
        ).state
    }

    private func setAsideCorruptFile() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: corruptURL)
        do {
            try fileManager.moveItem(at: fileURL, to: corruptURL)
        } catch {
            logger.error("Cannot set aside state.json: \(String(describing: error), privacy: .private)")
            isReadOnly = true
        }
    }

    // MARK: Journal of parked windows

    var hidden: [HiddenEntry] { state.hidden }

    /// Writes the entries to the journal and returns only after they are on disk. A window already in the
    /// journal keeps its earlier home frame: the frame it has now is the parked one. Throws, and leaves the
    /// journal unchanged, when the file cannot be written; the caller must then not park the windows.
    func addHidden(_ entries: [HiddenEntry]) throws {
        guard !isClosed else { throw StoreError.closed }
        guard !isReadOnly else { throw StoreError.readOnly }
        var next = state
        var known = Set(next.hidden.map(\.windowID))
        for entry in entries where known.insert(entry.windowID).inserted {
            next.hidden.append(entry)
        }
        guard next != state else { return }
        try writeThrough(next)
    }

    /// Removes windows from the journal (they were restored or are gone), written through.
    func removeHidden(_ ids: Set<WindowID>) throws {
        guard !isClosed else { throw StoreError.closed }
        guard !isReadOnly else { throw StoreError.readOnly }
        guard state.hidden.contains(where: { ids.contains($0.windowID) }) else { return }
        var next = state
        next.hidden.removeAll { ids.contains($0.windowID) }
        try writeThrough(next)
    }

    /// The journal entries that still describe the same window: pid, window number and process start time must
    /// match. `processStart` answers for a pid with the start time of the live process, or `nil` when it is
    /// gone. An entry that no longer matches is dropped from the journal and never moved.
    func validated(processStart: (Int32) -> TimeInterval?) throws -> [HiddenEntry] {
        var valid: [HiddenEntry] = []
        var stale = Set<WindowID>()
        for entry in state.hidden {
            if let live = processStart(entry.windowID.pid),
                abs(live - entry.processStart) <= Self.processStartTolerance
            {
                valid.append(entry)
            } else {
                stale.insert(entry.windowID)
            }
        }
        if !stale.isEmpty, !isReadOnly {
            logger.notice("Dropped \(stale.count, privacy: .public) stale journal entries")
            try removeHidden(stale)
        }
        return valid
    }

    private func writeThrough(_ next: WindowsState) throws {
        guard !isClosed else { throw StoreError.closed }
        do {
            let data = try Self.encode(StateFile(state: next))
            try AtomicFile.write(data, to: fileURL, syncDirectory: true)
        } catch {
            logger.error("Cannot write state.json: \(String(describing: error), privacy: .private)")
            throw StoreError.write
        }
        state = next
        isDirty = false
    }

    /// Forgets everything (*Reset state*): membership and the journal. The caller restores the windows first; what
    /// could not be restored (another Space) is forgotten with the rest, which is why the pane confirms. Written
    /// through. Throws when the file cannot be written.
    func reset() throws {
        guard !isClosed else { throw StoreError.closed }
        guard !isReadOnly else { throw StoreError.readOnly }
        saveTask?.cancel()
        saveTask = nil
        try writeThrough(.empty)
    }

    // MARK: Membership (deferred)

    /// Replaces the stored membership; written after `saveDelay`, or by `flush()`. Ignored while read-only.
    func setOrder(_ order: [WorkspaceID: [WindowID]]) {
        guard !isReadOnly, order != state.order else { return }
        state.order = order
        markDirty()
    }

    /// Replaces the stored state of every layout kind (written like the membership: after `saveDelay`, or by
    /// `flush()`). Ignored while read-only.
    func setLayouts(_ layouts: [WorkspaceID: [String: JSONValue]]) {
        guard !isReadOnly, layouts != state.layouts else { return }
        state.layouts = layouts
        markDirty()
    }

    /// Writes pending changes now.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty, !isReadOnly else { return }
        do {
            try AtomicFile.write(try Self.encode(StateFile(state: state)), to: fileURL)
            isDirty = false
        } catch {
            logger.error("Cannot write state.json: \(String(describing: error), privacy: .private)")
        }
    }

    /// Writes pending changes and stops the deferred save. Changes made after this are ignored until the next
    /// `load()`, so nothing is written by a late caller after the plugin was switched off.
    func close() {
        flush()
        saveTask?.cancel()
        saveTask = nil
        isClosed = true
    }

    #if DEBUG
    /// Waits for the deferred save that is scheduled right now, if any (tests only).
    func waitForPendingSave() async {
        await saveTask?.value
    }
    #endif

    private func markDirty() {
        guard !isClosed else { return }
        isDirty = true
        saveTask?.cancel()
        saveGeneration += 1
        let generation = saveGeneration
        let delay = saveDelay
        let clock = clock
        saveTask = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            await self?.saveIfCurrent(generation)
        }
    }

    private func saveIfCurrent(_ generation: Int) {
        guard generation == saveGeneration else { return }
        flush()
    }

    private static func encode(_ file: StateFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }
}
