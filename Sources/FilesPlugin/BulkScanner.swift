import Darwin
import Foundation
import Synchronization
import UniformTypeIdentifiers

/// What kind of item an index entry is.
enum EntryKind: UInt8, Sendable {
    case file = 0
    case directory = 1
    /// A bundle such as an `.app` or `.photoslibrary`: indexed as one item, never entered.
    case package = 2
    /// A symbolic link: indexed as itself, never followed.
    case symlink = 3
}

/// One item the scanner found.
struct ScannedEntry: Hashable, Sendable {
    let name: String
    let kind: EntryKind
    /// Modification time in seconds since 1970.
    let modified: UInt32
    /// For a directory the scanner enters: the id its own listing arrives under.
    let directoryID: Int32?
}

/// The listing of one directory. Directory `0` is the folder the scan started in; every other id was
/// announced by a `ScannedEntry.directoryID` in an earlier listing, so a listing always arrives after
/// its parent's.
struct ScannedDirectory: Hashable, Sendable {
    let id: Int32
    let entries: [ScannedEntry]
}

/// Lists directories with `getattrlistbulk(2)`, one system call per batch of entries, on several
/// threads at once (spec step 3.1).
///
/// - Packages (by type identifier or the bundle bit) are entries, never entered.
/// - Symbolic links are entries, never followed.
/// - Mount points and items on another device are skipped, so the scan never leaves the root's volume
///   (other volumes, firmlinks into `/System/Volumes/Data`).
/// - `IgnoreRules` decide what is left out; an excluded directory is never opened, so a protected folder
///   skipped without Full Disk Access never shows a privacy prompt.
/// - Unreadable directories are skipped silently.
/// - Only a root may be a symbolic link to a folder (`followsLink`): the scan starts in its target and
///   stays on the target's volume.
struct BulkScanner: Sendable {
    let rules: IgnoreRules
    let workerCount: Int
    /// Listings are delivered in batches of about this many entries.
    let batchSize: Int

    init(
        rules: IgnoreRules,
        workerCount: Int = max(2, ProcessInfo.processInfo.activeProcessorCount),
        batchSize: Int = 4096
    ) {
        self.rules = rules
        self.workerCount = max(1, workerCount)
        self.batchSize = max(1, batchSize)
    }

    /// The attributes of one path, without following a symbolic link unless `followsLink` (a root). `nil`
    /// when it does not exist.
    static func entry(at path: String, followsLink: Bool = false) -> (kind: EntryKind, modified: UInt32, device: Int32)?
    {
        var info = stat()
        guard (followsLink ? stat(path, &info) : lstat(path, &info)) == 0 else { return nil }
        let kind: EntryKind
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            kind = PackageTypes.shared.isPackage(name: PathText.name(path), bundleBit: false) ? .package : .directory
        case S_IFLNK:
            kind = .symlink
        default:
            kind = .file
        }
        return (kind, clampSeconds(info.st_mtimespec.tv_sec), Int32(info.st_dev))
    }

    /// Lists one directory without descending (the watcher's reconcile). `nil` when it cannot be read.
    /// `followsLink`: the path is a root, which may be a symbolic link to a folder.
    func list(_ path: String, followsLink: Bool = false) -> [ScannedEntry]? {
        guard let device = Self.entry(at: path, followsLink: followsLink)?.device else { return nil }
        var buffer = ListingBuffer()
        return buffer.list(path, device: device, rules: rules, followsLink: followsLink, nextID: { _ in nil })
    }

    /// Scans the tree below `path` (the folder itself is not reported). Returns `false` when cancelled.
    ///
    /// `deliver` is called serially, in discovery order, from the scanning threads; it must be quick.
    /// This call blocks until the scan ends, so never call it on a Swift concurrency thread (`IndexController`
    /// runs it on a GCD queue). `followsLink`: the path is a root, which may be a symbolic link to a folder.
    @discardableResult
    func scan(
        _ path: String,
        followsLink: Bool = false,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        deliver: @escaping @Sendable ([ScannedDirectory]) -> Void
    ) -> Bool {
        guard let device = Self.entry(at: path, followsLink: followsLink)?.device else { return !isCancelled() }
        let queue = WorkQueue(first: PendingDirectory(id: 0, path: path))
        let sink = ListingSink(batchSize: batchSize, deliver: deliver)
        let ids = Mutex<Int32>(0)
        let rules = rules

        DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
            var buffer = ListingBuffer()
            while let directory = queue.next() {
                if isCancelled() {
                    queue.cancel()
                    queue.finished()
                    break
                }
                var children: [PendingDirectory] = []
                let entries =
                    buffer.list(
                        directory.path, device: device, rules: rules, followsLink: followsLink && directory.id == 0,
                        nextID: { childPath in
                            let id = ids.withLock { value -> Int32 in
                                value += 1
                                return value
                            }
                            children.append(PendingDirectory(id: id, path: childPath))
                            return id
                        }
                    ) ?? []
                // The listing reaches the sink before its children are queued, so a parent always
                // arrives first.
                sink.add(ScannedDirectory(id: directory.id, entries: entries))
                queue.add(children)
                queue.finished()
            }
        }
        sink.flush()
        return !isCancelled()
    }

    static func clampSeconds(_ seconds: Int) -> UInt32 {
        UInt32(clamping: max(0, seconds))
    }
}

// MARK: - getattrlistbulk

private struct PendingDirectory: Sendable {
    let id: Int32
    let path: String
}

/// One thread's reusable buffer for `getattrlistbulk`.
private struct ListingBuffer {
    // Constants from <sys/attr.h> and <sys/vnode.h>, spelled out so their imported types do not matter.
    static let returnedAttributes: UInt32 = 0x8000_0000
    static let name: UInt32 = 0x0000_0001
    static let deviceID: UInt32 = 0x0000_0002
    static let objectType: UInt32 = 0x0000_0008
    static let modificationTime: UInt32 = 0x0000_0400
    static let finderInfo: UInt32 = 0x0000_4000
    static let flags: UInt32 = 0x0004_0000
    static let error: UInt32 = 0x2000_0000
    static let mountStatus: UInt32 = 0x0000_0004
    static let mountPoint: UInt32 = 0x0000_0001
    static let regular: UInt32 = 1
    static let directory: UInt32 = 2
    static let link: UInt32 = 5
    /// Finder flags: the item is a bundle (`kHasBundle`).
    static let hasBundle: UInt16 = 0x2000
    /// `UF_HIDDEN` in `st_flags`.
    static let hiddenFlag: UInt32 = 0x0000_8000

    static let size = 256 * 1024
    private var storage = [UInt8](repeating: 0, count: size)

    /// Lists `path`; `nextID` is called for each child directory to enter and returns its id. Returns
    /// `nil` when the directory cannot be opened or a read fails part way: a partial listing would make
    /// the index drop entries that still exist.
    mutating func list(
        _ path: String,
        device: Int32,
        rules: IgnoreRules,
        followsLink: Bool = false,
        nextID: (String) -> Int32?
    ) -> [ScannedEntry]? {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | (followsLink ? 0 : O_NOFOLLOW))
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr =
            Self.returnedAttributes | Self.name | Self.deviceID | Self.objectType | Self.modificationTime
            | Self.finderInfo | Self.flags | Self.error
        request.dirattr = Self.mountStatus

        var entries: [ScannedEntry] = []
        while true {
            let count = storage.withUnsafeMutableBytes { raw in
                getattrlistbulk(descriptor, &request, raw.baseAddress, raw.count, 0)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            storage.withUnsafeBytes { raw in
                var offset = 0
                for _ in 0..<count {
                    guard offset + 4 <= raw.count else { return }
                    let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                    guard length > 0, offset + length <= raw.count else { return }
                    if let parsed = Self.parse(raw, start: offset, length: length) {
                        if let entry = Self.entry(parsed, parent: path, device: device, rules: rules, nextID: nextID) {
                            entries.append(entry)
                        }
                    }
                    offset += length
                }
            }
        }
        return entries
    }

    private struct Parsed {
        var name = ""
        var device: Int32?
        var type: UInt32 = 0
        var modified: UInt32 = 0
        var finderFlags: UInt16 = 0
        var flags: UInt32 = 0
        var isMountPoint = false
    }

    /// Reads one entry. Attributes come in a fixed order: the returned set, the error, then the common
    /// attributes by bit value, then the directory attributes.
    private static func parse(_ raw: UnsafeRawBufferPointer, start: Int, length: Int) -> Parsed? {
        let end = start + length
        var cursor = start + 4
        func read<T>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard cursor + size <= end else { return nil }
            let value = raw.loadUnaligned(fromByteOffset: cursor, as: T.self)
            cursor += size
            return value
        }
        guard let common = read(UInt32.self), read(UInt32.self) != nil, let directoryAttributes = read(UInt32.self),
            read(UInt32.self) != nil, read(UInt32.self) != nil
        else { return nil }

        var parsed = Parsed()
        if common & error != 0 {
            guard let code = read(UInt32.self), code == 0 else { return nil }
        }
        if common & name != 0 {
            let referenceStart = cursor
            guard let dataOffset = read(Int32.self), let dataLength = read(UInt32.self) else { return nil }
            let nameStart = referenceStart + Int(dataOffset)
            let nameLength = Int(dataLength)
            guard nameLength > 0, nameStart >= start, nameStart + nameLength <= end else { return nil }
            // The length includes the terminating NUL.
            let bytes = UnsafeRawBufferPointer(rebasing: raw[nameStart..<nameStart + nameLength - 1])
            parsed.name = String(decoding: bytes, as: UTF8.self)
        }
        if common & deviceID != 0 {
            parsed.device = read(Int32.self)
        }
        if common & objectType != 0 {
            parsed.type = read(UInt32.self) ?? 0
        }
        if common & modificationTime != 0 {
            let seconds = read(Int.self) ?? 0
            _ = read(Int.self)
            parsed.modified = BulkScanner.clampSeconds(seconds)
        }
        if common & finderInfo != 0 {
            guard cursor + 32 <= end else { return nil }
            let high = raw[cursor + 8]
            let low = raw[cursor + 9]
            parsed.finderFlags = UInt16(high) << 8 | UInt16(low)
            cursor += 32
        }
        if common & flags != 0 {
            parsed.flags = read(UInt32.self) ?? 0
        }
        if directoryAttributes & mountStatus != 0 {
            parsed.isMountPoint = (read(UInt32.self) ?? 0) & mountPoint != 0
        }
        return parsed.name.isEmpty ? nil : parsed
    }

    private static func entry(
        _ parsed: Parsed,
        parent: String,
        device: Int32,
        rules: IgnoreRules,
        nextID: (String) -> Int32?
    ) -> ScannedEntry? {
        if parsed.isMountPoint || (parsed.device.map { $0 != device } ?? false) {
            return nil
        }
        let path = PathText.join(parent, parsed.name)
        let hidden = parsed.flags & hiddenFlag != 0
        if rules.excludes(name: parsed.name, path: path, hiddenFlag: hidden) {
            return nil
        }
        switch parsed.type {
        case directory:
            let isBundle = parsed.finderFlags & hasBundle != 0
            if PackageTypes.shared.isPackage(name: parsed.name, bundleBit: isBundle) {
                return ScannedEntry(name: parsed.name, kind: .package, modified: parsed.modified, directoryID: nil)
            }
            return ScannedEntry(
                name: parsed.name, kind: .directory, modified: parsed.modified, directoryID: nextID(path))
        case link:
            return ScannedEntry(name: parsed.name, kind: .symlink, modified: parsed.modified, directoryID: nil)
        default:
            return ScannedEntry(name: parsed.name, kind: .file, modified: parsed.modified, directoryID: nil)
        }
    }
}

/// Decides whether a directory is a package, caching the answer per file extension.
final class PackageTypes: Sendable {
    static let shared = PackageTypes()

    private let cache = Mutex<[String: Bool]>([:])

    func isPackage(name: String, bundleBit: Bool) -> Bool {
        if bundleBit { return true }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        guard !ext.isEmpty else { return false }
        if let known = cache.withLock({ $0[ext] }) {
            return known
        }
        // Package types are directory types, so the lookup must ask for one.
        let type = UTType(filenameExtension: ext, conformingTo: .directory)
        let answer = type.map { !$0.isDynamic && $0.conforms(to: .package) } ?? false
        cache.withLock { $0[ext] = answer }
        return answer
    }
}

// MARK: - Work distribution

/// The directories still to list, shared by the scanning threads. A thread that finds the queue empty
/// waits while other threads may still add directories, and every thread stops once nothing is queued
/// and nothing is being listed.
private final class WorkQueue: @unchecked Sendable {
    // @unchecked: every stored property is read and written only while `condition` is locked.
    private let condition = NSCondition()
    private var pending: [PendingDirectory]
    private var inFlight = 0
    private var cancelled = false

    init(first: PendingDirectory) {
        pending = [first]
    }

    /// The next directory to list, or `nil` when the scan is over. The caller must call `finished()`
    /// after listing it.
    func next() -> PendingDirectory? {
        condition.lock()
        defer { condition.unlock() }
        while pending.isEmpty, inFlight > 0, !cancelled {
            condition.wait()
        }
        guard !cancelled, let directory = pending.popLast() else { return nil }
        inFlight += 1
        return directory
    }

    func add(_ directories: [PendingDirectory]) {
        guard !directories.isEmpty else { return }
        condition.lock()
        pending.append(contentsOf: directories)
        condition.broadcast()
        condition.unlock()
    }

    func finished() {
        condition.lock()
        inFlight -= 1
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        pending.removeAll()
        condition.broadcast()
        condition.unlock()
    }
}

/// Collects listings and delivers them in batches, in the order they were added.
private final class ListingSink: Sendable {
    private struct State {
        var listings: [ScannedDirectory] = []
        var entries = 0
    }

    private let state = Mutex(State())
    private let batchSize: Int
    private let deliver: @Sendable ([ScannedDirectory]) -> Void

    init(batchSize: Int, deliver: @escaping @Sendable ([ScannedDirectory]) -> Void) {
        self.batchSize = batchSize
        self.deliver = deliver
    }

    func add(_ listing: ScannedDirectory) {
        state.withLock { state in
            state.listings.append(listing)
            state.entries += max(1, listing.entries.count)
            guard state.entries >= batchSize else { return }
            // Delivering under the lock keeps batches in order; `deliver` only hands them over.
            deliver(state.listings)
            state.listings.removeAll(keepingCapacity: true)
            state.entries = 0
        }
    }

    func flush() {
        state.withLock { state in
            guard !state.listings.isEmpty else { return }
            deliver(state.listings)
            state.listings.removeAll()
            state.entries = 0
        }
    }
}
