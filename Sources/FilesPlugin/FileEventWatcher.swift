import CoreServices
import Foundation
import Synchronization

/// One FSEvents event.
struct FileEvent: Hashable, Sendable {
    let path: String
    let flags: UInt32
    let id: UInt64

    func has(_ flag: Int) -> Bool {
        flags & UInt32(flag) != 0
    }
}

/// Watches the index roots with FSEvents (spec step 3.4): file-level events, coalesced by FSEvents for
/// `latency`, optionally replayed from an earlier event id (`sinceWhen`).
///
/// Events go into a buffer and a wake-up signal goes into an `AsyncStream` with `.bufferingNewest(1)`, so a
/// slow consumer never blocks FSEvents and never loses an event: it drains the whole buffer on each
/// wake-up. If the buffer overflows, `drain()` reports it and the consumer rescans.
final class FileEventWatcher: Sendable {
    static let maximumBuffered = 200_000

    private struct Buffer {
        var events: [FileEvent] = []
        var overflowed = false
    }

    /// Owns the FSEvents stream; the C callback reaches the watcher through this box.
    private final class StreamBox: Sendable {
        let watcher = WeakWatcher()
    }

    /// The watcher as the callback sees it: gone once the watcher is released.
    private final class WeakWatcher: @unchecked Sendable {
        // @unchecked: a weak reference set once, before the stream starts, and only read afterwards.
        weak var value: FileEventWatcher?
    }

    private let paths: [String]
    private let sinceWhen: UInt64
    private let latency: TimeInterval
    private let buffer = Mutex(Buffer())
    private let stream = Mutex<StreamHandle?>(nil)

    /// The FSEvents stream reference.
    private struct StreamHandle: @unchecked Sendable {
        // @unchecked: an opaque CoreServices reference; it is only stopped, invalidated and released once,
        // by whoever takes it out of the mutex.
        let ref: FSEventStreamRef
    }
    private let queue = DispatchQueue(label: "app.pounce.files.events", qos: .utility)
    private let continuation: AsyncStream<Void>.Continuation
    /// Yields after new events were buffered.
    let wakeups: AsyncStream<Void>

    init(paths: [String], sinceWhen: UInt64?, latency: TimeInterval = 0.5) {
        self.paths = paths
        self.sinceWhen = sinceWhen ?? UInt64(kFSEventStreamEventIdSinceNow)
        self.latency = latency
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.wakeups = stream
        self.continuation = continuation
    }

    deinit {
        stop()
    }

    /// The current FSEvents event id; events after it are not yet delivered.
    static var currentEventID: UInt64 {
        FSEventsGetCurrentEventId()
    }

    /// The UUID of the FSEvents database of a path's volume, or `nil` when the volume has none. A
    /// different UUID means the event history no longer matches a saved snapshot.
    static func deviceUUID(of path: String) -> String? {
        var info = stat()
        // A root may be a symbolic link to a folder: its target's volume is the one that matters.
        guard stat(path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// Starts the stream. Returns `false` when FSEvents refused it.
    @discardableResult
    func start() -> Bool {
        guard stream.withLock({ $0 == nil }), !paths.isEmpty else { return false }
        let box = StreamBox()
        box.watcher.value = self
        // FSEvents keeps the box alive until the stream is released (the retain and release callbacks).
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<StreamBox>.fromOpaque(info).retain()
                return UnsafeRawPointer(info)
            },
            release: { info in
                guard let info else { return }
                Unmanaged<StreamBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, rawIDs in
            guard let info else { return }
            let box = Unmanaged<StreamBox>.fromOpaque(info).takeUnretainedValue()
            let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var events: [FileEvent] = []
            events.reserveCapacity(count)
            for index in 0..<count {
                events.append(
                    FileEvent(path: String(cString: paths[index]), flags: rawFlags[index], id: rawIDs[index]))
            }
            box.watcher.value?.receive(events)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard
            let created = FSEventStreamCreate(
                nil, callback, &context, paths as CFArray, FSEventStreamEventId(sinceWhen), latency, flags)
        else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        let handle = StreamHandle(ref: created)
        stream.withLock { $0 = handle }
        return true
    }

    /// Stops and releases the stream. Idempotent.
    func stop() {
        if let running = stream.withLock({ value -> StreamHandle? in
            defer { value = nil }
            return value
        }) {
            FSEventStreamStop(running.ref)
            FSEventStreamInvalidate(running.ref)
            FSEventStreamRelease(running.ref)
        }
        continuation.finish()
    }

    /// Takes every buffered event; `overflowed` is true when some were dropped.
    func drain() -> (events: [FileEvent], overflowed: Bool) {
        buffer.withLock { buffer in
            defer { buffer = Buffer() }
            return (buffer.events, buffer.overflowed)
        }
    }

    private func receive(_ events: [FileEvent]) {
        buffer.withLock { buffer in
            if buffer.events.count + events.count > Self.maximumBuffered {
                buffer.overflowed = true
                buffer.events.removeAll()
            } else {
                buffer.events.append(contentsOf: events)
            }
        }
        continuation.yield()
    }
}

/// What a batch of events asks the index to do (spec: Edge Cases, FSEvents).
struct RescanPlan: Equatable, Sendable {
    /// Roots to scan again from scratch (`RootChanged`).
    var roots: Set<String> = []
    /// Every root: events were dropped or event ids wrapped.
    var everything = false
    /// Subtrees to scan again (`MustScanSubDirs`).
    var subtrees: Set<String> = []
    /// Folders whose children to compare with a fresh listing (ordinary changes).
    var folders: Set<String> = []
    /// The replay of past events reached the present (`HistoryDone`).
    var historyDone = false
    /// The highest event id in the batch.
    var lastEventID: UInt64 = 0

    var isEmpty: Bool {
        roots.isEmpty && !everything && subtrees.isEmpty && folders.isEmpty
    }
}

/// Turns FSEvents events into the smallest set of rescans, coalesced: duplicates are merged, and a folder
/// or subtree inside another subtree or root being rescanned is dropped.
enum RescanPlanner {
    /// - Parameter aliases: the canonical path FSEvents reports for a root (`/private/var/…` for
    ///   `/var/…`, the target of a symlinked root) mapped to the root as the index knows it.
    static func plan(
        _ events: [FileEvent], roots: [String], rules: IgnoreRules, aliases: [String: String] = [:]
    ) -> RescanPlan {
        var plan = RescanPlan()
        for event in events {
            plan.lastEventID = max(plan.lastEventID, event.id)
            if event.has(kFSEventStreamEventFlagHistoryDone) {
                plan.historyDone = true
                continue
            }
            if event.has(kFSEventStreamEventFlagUserDropped) || event.has(kFSEventStreamEventFlagKernelDropped)
                || event.has(kFSEventStreamEventFlagEventIdsWrapped)
            {
                plan.everything = true
                continue
            }
            let path = unaliased(standardized(event.path), aliases: aliases)
            if event.has(kFSEventStreamEventFlagRootChanged) {
                // The path is a watched root (or one of its ancestors) that moved or was deleted.
                for root in roots where PathText.contains(path, root) || path == root {
                    plan.roots.insert(root)
                }
                continue
            }
            if event.has(kFSEventStreamEventFlagMustScanSubDirs) {
                // An ancestor of roots (`/` when the event history is incomplete): rescan the roots below it.
                let below = roots.filter { $0 != path && PathText.contains(path, $0) }
                if !below.isEmpty {
                    plan.roots.formUnion(below)
                    continue
                }
            }
            guard let root = roots.filter({ PathText.contains($0, path) }).max(by: { $0.count < $1.count }) else {
                continue
            }
            if event.has(kFSEventStreamEventFlagMustScanSubDirs) {
                if !rules.excludesBelow(root: root, path: path) {
                    plan.subtrees.insert(path)
                }
                continue
            }
            // A change to an item shows in its folder's listing; a change to the root shows in the root.
            let folder = path == root ? root : PathText.parent(path)
            if !rules.excludesBelow(root: root, path: folder) {
                plan.folders.insert(folder)
            }
        }
        return coalesced(plan, roots: roots)
    }

    static func coalesced(_ plan: RescanPlan, roots: [String]) -> RescanPlan {
        var result = plan
        if result.everything {
            result.roots = Set(roots)
            result.subtrees = []
            result.folders = []
            return result
        }
        let covering = result.roots
        result.subtrees = Set(
            result.subtrees.filter { subtree in
                !covering.contains { PathText.contains($0, subtree) }
                    && !result.subtrees.contains { $0 != subtree && PathText.contains($0, subtree) }
            })
        let scanned = covering.union(result.subtrees)
        result.folders = Set(result.folders.filter { folder in !scanned.contains { PathText.contains($0, folder) } })
        return result
    }

    /// Maps a path below a root's canonical path back below the root (the longest canonical path wins,
    /// for nested roots).
    static func unaliased(_ path: String, aliases: [String: String]) -> String {
        guard
            let (canonical, root) = aliases.filter({ PathText.contains($0.key, path) })
                .max(by: { $0.key.count < $1.key.count })
        else { return path }
        return root + path.dropFirst(canonical.count)
    }

    /// The canonical path of each root that differs from the root (symlinks resolved, `/private` kept).
    static func aliases(of roots: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for root in roots {
            guard let resolved = realpath(root, nil) else { continue }
            let canonical = String(cString: resolved)
            free(resolved)
            if canonical != root {
                result[canonical] = root
            }
        }
        return result
    }

    /// FSEvents reports paths with a trailing slash for some folders and `/private` for temporary ones
    /// only when the watched path has it; keep the path as given, without a trailing slash.
    static func standardized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
