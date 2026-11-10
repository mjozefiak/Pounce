import Foundation
import LintelPersistence
import os

/// Owner of `Plugins/windows/layouts.json`: the user's grid layouts and the nine layout slots (spec: Data Model,
/// Q18). Stock templates are compiled in and never written. Same rules as `AssignmentStore`: versioned with a
/// migration seam, written at once through `AtomicFile`, one `.corrupt` copy when the file does not parse, a file
/// from a newer version is read as well as it can be and never written. A layout this build does not understand
/// (another style such as the reserved `canvas`, or a grid that breaks a rule) is kept untouched on every save and
/// is never offered for assignment. Layout names are user data: never logged beyond counts.
actor LayoutRepository {
    static let fileName = "layouts.json"
    static let corruptFileName = "layouts.json.corrupt"

    enum RepositoryError: Error, Equatable {
        case readOnly
        case write
        case notFound
        /// A stock template cannot be changed, renamed or deleted (duplicate it).
        case stock
        case invalid(LayoutRejection)
        case limit
    }

    /// One step of the version migration seam: turns the JSON of version N into the JSON of version N + 1.
    typealias Migration = @Sendable (Data) -> Data?

    nonisolated let fileURL: URL
    nonisolated var corruptURL: URL { fileURL.deletingLastPathComponent().appending(path: Self.corruptFileName) }
    private let logger: Logger
    private let currentVersion: Int
    private let migrations: [Int: Migration]
    private var document = LayoutDocument(version: LayoutRules.currentVersion, entries: [], slots: [:])
    private(set) var isReadOnly = false

    init(
        directory: URL, currentVersion: Int = LayoutRules.currentVersion, migrations: [Int: Migration] = [:],
        logger: Logger = Logger(subsystem: "com.lintelapp", category: "windows")
    ) {
        fileURL = directory.appending(path: Self.fileName)
        self.currentVersion = currentVersion
        self.migrations = migrations
        self.logger = logger
    }

    // MARK: Reading

    /// The user's own layouts, in file order.
    var userLayouts: [GridLayout] { document.gridLayouts }

    /// The stock templates and the user's layouts: what assignment and placement resolve against.
    var library: LayoutLibrary { LayoutLibrary(StockLayouts.all + document.gridLayouts) }

    /// Entries kept untouched (another style, or invalid): counted, never shown as layouts.
    var keptUntouchedCount: Int { document.entries.count - document.gridLayouts.count }

    /// Slot number (1 to 9) to the layout bound to it. A slot whose layout is gone is not listed.
    var slots: [Int: String] {
        let known = library
        return document.slots.filter { known.contains($0.value) }
    }

    func layout(_ id: String) -> GridLayout? { library.layout(id) }

    var snapshot: Snapshot { Snapshot(user: userLayouts, slots: slots, isReadOnly: isReadOnly) }

    /// The library as plain values for the window.
    struct Snapshot: Equatable, Sendable {
        var user: [GridLayout]
        var slots: [Int: String]
        var isReadOnly: Bool
    }

    // MARK: Loading

    func load() {
        isReadOnly = false
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            reset()
            if (error as NSError).code != NSFileReadNoSuchFileError {
                logger.error("Cannot read layouts.json")
                isReadOnly = true
            }
            return
        }
        struct Header: Decodable { var version: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.version >= 1 else {
            logger.error("layouts.json is corrupt; starting without user layouts")
            setAsideCorruptFile()
            reset()
            return
        }
        if header.version > currentVersion {
            logger.notice("layouts.json comes from a newer version; it is read-only")
            document = (try? LayoutDocument.parse(data)) ?? emptyDocument
            isReadOnly = true
            return
        }
        var current = data
        var version = header.version
        while version < currentVersion {
            guard let step = migrations[version], let next = step(current) else {
                logger.error("layouts.json cannot be migrated")
                setAsideCorruptFile()
                reset()
                return
            }
            current = next
            version += 1
        }
        guard let parsed = try? LayoutDocument.parse(current) else {
            logger.error("layouts.json is corrupt; starting without user layouts")
            setAsideCorruptFile()
            reset()
            return
        }
        document = parsed
        document.version = currentVersion
    }

    private var emptyDocument: LayoutDocument { LayoutDocument(version: currentVersion, entries: [], slots: [:]) }

    private func reset() { document = emptyDocument }

    private func setAsideCorruptFile() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: corruptURL)
        do {
            try fileManager.moveItem(at: fileURL, to: corruptURL)
        } catch {
            logger.error("Cannot set aside layouts.json")
            isReadOnly = true
        }
    }

    // MARK: Changing

    private var allIDs: Set<String> {
        Set(StockLayouts.all.map(\.id)).union(document.entries.compactMap(\.id))
    }

    /// A fresh id that is in no layout of the library (kept ones included).
    private func freshID(avoiding taken: Set<String>) -> String {
        var id: String
        repeat { id = LayoutRules.userIDPrefix + UUID().uuidString.lowercased() } while taken.contains(id)
        return id
    }

    private func cleaned(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Adds a layout as a new one: the id is always generated (stable from then on). Returns what was stored.
    @discardableResult
    func create(_ draft: GridLayout) throws -> GridLayout {
        var fresh = draft
        fresh.id = ""
        return try add([fresh])[0]
    }

    /// Adds many layouts in one write (create and import): ids are generated for every layout whose own id is
    /// empty, malformed or already taken, and kept otherwise. Nothing is added when any layout breaks a rule.
    @discardableResult
    func add(_ drafts: [GridLayout]) throws -> [GridLayout] {
        guard !isReadOnly else { throw RepositoryError.readOnly }
        guard document.entries.count + drafts.count <= LayoutRules.maximumLayouts else {
            throw RepositoryError.limit
        }
        var taken = allIDs
        var added: [GridLayout] = []
        for var draft in drafts {
            draft.name = cleaned(draft.name)
            if !LayoutRules.isValidUserID(draft.id) || taken.contains(draft.id) {
                draft.id = freshID(avoiding: taken)
            }
            if let rejection = LayoutRules.check(draft) { throw RepositoryError.invalid(rejection) }
            taken.insert(draft.id)
            added.append(draft)
        }
        var next = document
        next.entries.append(contentsOf: added.map { .grid($0) })
        try write(next)
        return added
    }

    /// An editable copy of any layout (stock ones included) under a new id.
    @discardableResult
    func duplicate(_ id: String, name: String) throws -> GridLayout {
        guard let source = library.layout(id) else { throw RepositoryError.notFound }
        var copy = source
        copy.name = name
        copy.id = ""
        return try create(copy)
    }

    func rename(_ id: String, to name: String) throws {
        guard var layout = userLayout(id) else { throw missing(id) }
        layout.name = cleaned(name)
        try replace(layout)
    }

    /// Saves an edited layout under its own id (the editor's *Save*).
    func replace(_ layout: GridLayout) throws {
        guard !isReadOnly else { throw RepositoryError.readOnly }
        guard let index = document.entries.firstIndex(where: { $0.id == layout.id && isGrid($0) }) else {
            throw missing(layout.id)
        }
        var value = layout
        value.name = cleaned(value.name)
        if let rejection = LayoutRules.check(value) { throw RepositoryError.invalid(rejection) }
        var next = document
        next.entries[index] = .grid(value)
        try write(next)
    }

    /// Deletes a user's layout, gives every assignment that used it back to the display default and frees its
    /// slots. Returns how many assignments changed (the confirmation names the same number).
    @discardableResult
    func delete(_ id: String, assignments: AssignmentStore) async throws -> Int {
        guard !isReadOnly else { throw RepositoryError.readOnly }
        guard userLayout(id) != nil else { throw missing(id) }
        // Assignments first: if this fails nothing was deleted; if the next write fails the cells simply use the
        // default and the layout is still there.
        let changed: Int
        do {
            changed = try await assignments.removeAll(using: id)
        } catch {
            throw RepositoryError.write
        }
        var next = document
        next.entries.removeAll { $0.id == id && isGrid($0) }
        next.slots = next.slots.filter { $0.value != id }
        try write(next)
        return changed
    }

    /// Binds a layout slot (1 to 9) to a layout, or frees it with `nil`.
    func setSlot(_ number: Int, to layoutID: String?) throws {
        guard !isReadOnly else { throw RepositoryError.readOnly }
        guard (1...LayoutRules.slotCount).contains(number) else { throw RepositoryError.notFound }
        if let layoutID, !library.contains(layoutID) { throw RepositoryError.notFound }
        var next = document
        next.slots[number] = layoutID
        try write(next)
    }

    private func isGrid(_ entry: LayoutEntry) -> Bool {
        if case .grid = entry { return true }
        return false
    }

    private func userLayout(_ id: String) -> GridLayout? { document.gridLayouts.first { $0.id == id } }

    private func missing(_ id: String) -> RepositoryError {
        StockLayouts.isStock(id) ? .stock : .notFound
    }

    private func write(_ next: LayoutDocument) throws {
        guard !isReadOnly else { throw RepositoryError.readOnly }
        guard next != document else { return }
        var versioned = next
        versioned.version = currentVersion
        do {
            try AtomicFile.write(try versioned.encoded(), to: fileURL)
        } catch {
            logger.error("Cannot write layouts.json")
            throw RepositoryError.write
        }
        document = versioned
    }
}
