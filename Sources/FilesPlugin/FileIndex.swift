import Foundation
import Synchronization

/// The only owner of the file index (spec: Współbieżność). Changes arrive in batches (scan listings,
/// FSEvents reconciles); after a batch the actor publishes an immutable copy of its `NameStore`.
/// Searches read the published copy through `snapshot` without waiting for the actor, so they never see
/// half a batch and never wait for a scan (read-copy-update).
actor FileIndex {
    private var store = NameStore()
    private let published = Mutex(NameStore())
    /// Scan-local directory ids mapped to nodes, per running scan.
    private var scans: [Int: [Int32: Int32]] = [:]
    private var nextScan = 0
    /// Compact when this share of the arrays holds removed nodes.
    static let compactionThreshold = 0.25

    init(_ initial: NameStore = NameStore()) {
        store = initial
        published.withLock { $0 = initial }
    }

    /// The latest published index. Safe from any thread, never blocks on the actor.
    nonisolated var snapshot: NameStore {
        published.withLock { $0 }
    }

    /// Makes the current state visible to searches.
    func publish() {
        if store.wasteRatio > Self.compactionThreshold, store.removedCount > 1024, scans.isEmpty {
            store = store.compacted()
        }
        let copy = store
        published.withLock { $0 = copy }
    }

    /// Replaces the whole index (a loaded snapshot) and publishes it.
    func replace(with newStore: NameStore) {
        store = newStore
        scans.removeAll()
        publish()
    }

    var count: Int { store.liveCount }

    /// The live index, including changes not published yet.
    var current: NameStore { store }

    /// A copy of the live index (for saving).
    func currentStore() -> NameStore { store }

    /// Removes every root that is not in `paths` and adds the missing ones. Returns the root nodes in
    /// the order of `paths`; a root that does not exist on disk is left out.
    func setRoots(_ paths: [String], attributes: (String) -> (kind: EntryKind, modified: UInt32)?) -> [String: Int32] {
        for root in store.roots where !paths.contains(store.name(root)) {
            store.remove(root)
        }
        var result: [String: Int32] = [:]
        for path in paths {
            if let existing = store.root(path) {
                result[path] = existing
            } else if let info = attributes(path) {
                result[path] = store.addRoot(path: path, kind: info.kind, modified: info.modified)
            }
        }
        return result
    }

    // MARK: Scans

    /// Starts absorbing a scan of the folder at `node`: its old contents are removed first.
    func beginScan(at node: Int32) -> Int {
        store.removeChildren(of: node)
        let token = nextScan
        nextScan += 1
        scans[token] = [0: node]
        return token
    }

    /// Adds scanned listings below the scan's folder. Returns the live entry count.
    @discardableResult
    func absorb(_ listings: [ScannedDirectory], scan token: Int) -> Int {
        guard var map = scans[token] else { return store.liveCount }
        for listing in listings {
            guard let parent = map[listing.id], store.isLive(parent) else { continue }
            for entry in listing.entries {
                let node = store.addChild(entry.name, kind: entry.kind, modified: entry.modified, parent: parent)
                if let id = entry.directoryID {
                    map[id] = node
                }
            }
        }
        scans[token] = map
        return store.liveCount
    }

    func endScan(_ token: Int) {
        scans[token] = nil
    }

    // MARK: Changes

    /// Brings one folder's children in line with a fresh listing. Returns the new child folders, which
    /// the caller scans. Does nothing when the folder at `path` is no longer `node`.
    func reconcile(node: Int32, path: String, listing: [ScannedEntry]) -> [(node: Int32, path: String)] {
        guard store.isLive(node), store.path(node) == path else { return [] }
        var existing: [String: Int32] = [:]
        for child in store.children(node) {
            existing[store.name(child)] = child
        }
        var newFolders: [(node: Int32, path: String)] = []
        for entry in listing {
            if let child = existing.removeValue(forKey: entry.name) {
                if store.kind(child) == entry.kind {
                    store.setModified(child, entry.modified)
                    continue
                }
                store.remove(child)
            }
            let child = store.addChild(entry.name, kind: entry.kind, modified: entry.modified, parent: node)
            if entry.kind == .directory {
                newFolders.append((child, PathText.join(path, entry.name)))
            }
        }
        for child in existing.values {
            store.remove(child)
        }
        return newFolders
    }

    /// Removes the node at `path` and everything below it.
    func remove(path: String) {
        if let node = store.locate(path).node {
            store.remove(node)
        }
    }

    /// Updates a node's modification time.
    func touch(node: Int32, modified: UInt32) {
        guard store.isLive(node) else { return }
        store.setModified(node, modified)
    }
}
