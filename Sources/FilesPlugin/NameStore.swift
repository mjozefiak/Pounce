import Foundation
import PounceCore

/// The file index as flat arrays (spec: Architecture, `NameStore`): a name pool and a node table with
/// the parent index, so a million entries cost tens of bytes each instead of a `String` path each.
///
/// Node `i` has its raw UTF-8 name in `namePool[nameStarts[i] ..< + nameLengths[i]]` and its normalised
/// name (lowercase, folded like `TextNormalizer`) in `foldPool`, or shares the raw bytes when they are
/// equal. Children of a directory form a singly linked list (`firstChild`, `nextSibling`). Removed nodes
/// stay in the arrays, flagged, until `compacted()` rebuilds them.
///
/// It is a value type: `FileIndex` mutates its own copy and publishes copies as immutable snapshots,
/// so a search never sees half of a batch.
struct NameStore: Sendable {
    struct Flags: OptionSet, Hashable, Sendable {
        let rawValue: UInt8
        static let directory = Flags(rawValue: 1 << 0)
        static let package = Flags(rawValue: 1 << 1)
        static let symlink = Flags(rawValue: 1 << 2)
        static let removed = Flags(rawValue: 1 << 3)
        /// A root: its name is the root's whole path, and it is never a search result.
        static let root = Flags(rawValue: 1 << 4)
    }

    static let none: Int32 = -1
    /// `foldStarts` value meaning "same bytes as the raw name".
    static let sameAsRaw = UInt32.max

    private(set) var parents: [Int32] = []
    private(set) var firstChild: [Int32] = []
    private(set) var nextSibling: [Int32] = []
    private(set) var flags: [Flags] = []
    private(set) var modified: [UInt32] = []
    private(set) var nameStarts: [UInt32] = []
    private(set) var nameLengths: [UInt16] = []
    private(set) var foldStarts: [UInt32] = []
    private(set) var foldLengths: [UInt16] = []
    private(set) var namePool: [UInt8] = []
    private(set) var foldPool: [UInt8] = []
    private(set) var roots: [Int32] = []
    /// Live entries, roots excluded.
    private(set) var liveCount = 0
    private(set) var removedCount = 0

    var nodeCount: Int { parents.count }

    // MARK: Reading

    func isLive(_ node: Int32) -> Bool {
        node >= 0 && Int(node) < flags.count && !flags[Int(node)].contains(.removed)
    }

    func name(_ node: Int32) -> String {
        let index = Int(node)
        let start = Int(nameStarts[index])
        return String(decoding: namePool[start..<start + Int(nameLengths[index])], as: UTF8.self)
    }

    /// The absolute path of a node.
    func path(_ node: Int32) -> String {
        var components: [String] = []
        var current = node
        while current != Self.none {
            components.append(name(current))
            if flags[Int(current)].contains(.root) { break }
            current = parents[Int(current)]
        }
        guard let root = components.popLast() else { return "" }
        return components.reversed().reduce(root) { PathText.join($0, $1) }
    }

    /// How many folders lie between the node and its root.
    func depth(_ node: Int32) -> Int {
        var depth = 0
        var current = parents[Int(node)]
        while current != Self.none, !flags[Int(current)].contains(.root) {
            depth += 1
            current = parents[Int(current)]
        }
        return depth
    }

    func kind(_ node: Int32) -> EntryKind {
        let flags = flags[Int(node)]
        if flags.contains(.package) { return .package }
        if flags.contains(.directory) { return .directory }
        if flags.contains(.symlink) { return .symlink }
        return .file
    }

    /// Live children of a directory.
    func children(_ node: Int32) -> [Int32] {
        var result: [Int32] = []
        var child = firstChild[Int(node)]
        while child != Self.none {
            if isLive(child) { result.append(child) }
            child = nextSibling[Int(child)]
        }
        return result
    }

    /// The live child with this exact name.
    func child(named name: String, of node: Int32) -> Int32? {
        let bytes = Array(name.utf8)
        var child = firstChild[Int(node)]
        while child != Self.none {
            if isLive(child), rawBytesEqual(child, bytes) { return child }
            child = nextSibling[Int(child)]
        }
        return nil
    }

    private func rawBytesEqual(_ node: Int32, _ bytes: [UInt8]) -> Bool {
        let index = Int(node)
        guard Int(nameLengths[index]) == bytes.count else { return false }
        let start = Int(nameStarts[index])
        return namePool[start..<start + bytes.count].elementsEqual(bytes)
    }

    /// The root node of a root path.
    func root(_ path: String) -> Int32? {
        roots.first { isLive($0) && name($0) == path }
    }

    /// Finds the node at a path. `deepest` is the deepest live node on the way (the root, a folder, or
    /// the node itself), and `node` is set only when the whole path exists in the index.
    func locate(_ path: String) -> (node: Int32?, deepest: Int32?) {
        guard
            let root = roots.filter({ isLive($0) && PathText.contains(name($0), path) })
                .max(by: { name($0).count < name($1).count })
        else { return (nil, nil) }
        let rootPath = name(root)
        if rootPath == path { return (root, root) }
        let relative = rootPath == "/" ? path.dropFirst() : path.dropFirst(rootPath.count + 1)
        var current = root
        for component in relative.split(separator: "/") {
            guard let next = child(named: String(component), of: current) else { return (nil, current) }
            current = next
        }
        return (current, current)
    }

    /// The normalised name bytes of a node (what search matches against).
    @inline(__always)
    func withFoldedBytes<R>(_ node: Int, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        let foldStart = foldStarts[node]
        if foldStart == Self.sameAsRaw {
            let start = Int(nameStarts[node])
            return namePool.withUnsafeBufferPointer { pool in
                body(UnsafeBufferPointer(rebasing: pool[start..<start + Int(nameLengths[node])]))
            }
        }
        let start = Int(foldStart)
        return foldPool.withUnsafeBufferPointer { pool in
            body(UnsafeBufferPointer(rebasing: pool[start..<start + Int(foldLengths[node])]))
        }
    }

    // MARK: Writing

    /// Adds a root (its name is the whole path).
    @discardableResult
    mutating func addRoot(path: String, kind: EntryKind, modified: UInt32) -> Int32 {
        let node = append(name: path, folded: nil, parent: Self.none, kind: kind, modified: modified, root: true)
        roots.append(node)
        return node
    }

    /// Adds a child at the front of its parent's list.
    @discardableResult
    mutating func addChild(_ name: String, kind: EntryKind, modified: UInt32, parent: Int32) -> Int32 {
        let node = append(
            name: name, folded: Self.fold(name), parent: parent, kind: kind, modified: modified, root: false)
        nextSibling[Int(node)] = firstChild[Int(parent)]
        firstChild[Int(parent)] = node
        liveCount += 1
        return node
    }

    /// Adds a child from stored bytes (a loaded snapshot).
    @discardableResult
    mutating func addChild(raw: [UInt8], folded: [UInt8], flags: Flags, modified: UInt32, parent: Int32) -> Int32 {
        let node = appendBytes(raw: raw, folded: folded, parent: parent, flags: flags, modified: modified)
        nextSibling[Int(node)] = firstChild[Int(parent)]
        firstChild[Int(parent)] = node
        liveCount += 1
        return node
    }

    mutating func setModified(_ node: Int32, _ value: UInt32) {
        modified[Int(node)] = value
    }

    /// Removes a node and everything below it.
    mutating func remove(_ node: Int32) {
        guard isLive(node) else { return }
        let parent = parents[Int(node)]
        if parent != Self.none {
            unlink(node, from: parent)
        } else {
            roots.removeAll { $0 == node }
        }
        markRemoved(node)
    }

    /// Removes everything below a directory, keeping the directory.
    mutating func removeChildren(of node: Int32) {
        var child = firstChild[Int(node)]
        while child != Self.none {
            let next = nextSibling[Int(child)]
            markRemoved(child)
            child = next
        }
        firstChild[Int(node)] = Self.none
    }

    /// The fraction of the arrays taken by removed nodes; `FileIndex` compacts above a threshold.
    var wasteRatio: Double {
        nodeCount == 0 ? 0 : Double(removedCount) / Double(nodeCount)
    }

    /// The same live tree in fresh arrays without removed nodes or unused pool bytes.
    func compacted() -> NameStore {
        var result = NameStore()
        result.reserve(liveCount + roots.count, nameBytes: namePool.count, foldBytes: foldPool.count)
        for root in roots where isLive(root) {
            let newRoot = result.addRoot(path: name(root), kind: kind(root), modified: modified[Int(root)])
            var stack: [(Int32, Int32)] = [(root, newRoot)]
            while let (old, new) = stack.popLast() {
                // Children are prepended, so walking the old list backwards keeps their order.
                for child in children(old).reversed() {
                    let copy = result.copyChild(child, from: self, parent: new)
                    stack.append((child, copy))
                }
            }
        }
        return result
    }

    mutating func reserve(_ nodes: Int, nameBytes: Int, foldBytes: Int) {
        parents.reserveCapacity(nodes)
        firstChild.reserveCapacity(nodes)
        nextSibling.reserveCapacity(nodes)
        flags.reserveCapacity(nodes)
        modified.reserveCapacity(nodes)
        nameStarts.reserveCapacity(nodes)
        nameLengths.reserveCapacity(nodes)
        foldStarts.reserveCapacity(nodes)
        foldLengths.reserveCapacity(nodes)
        namePool.reserveCapacity(nameBytes)
        foldPool.reserveCapacity(foldBytes)
    }

    /// Rough heap size of the arrays (capacity, not count), for the memory measurement.
    var approximateBytes: Int {
        parents.capacity * 4 + firstChild.capacity * 4 + nextSibling.capacity * 4 + flags.capacity
            + modified.capacity * 4 + nameStarts.capacity * 4 + nameLengths.capacity * 2 + foldStarts.capacity * 4
            + foldLengths.capacity * 2 + namePool.capacity + foldPool.capacity + roots.capacity * 4
    }

    // MARK: Private

    private mutating func copyChild(_ child: Int32, from source: NameStore, parent: Int32) -> Int32 {
        let index = Int(child)
        let start = Int(source.nameStarts[index])
        let raw = Array(source.namePool[start..<start + Int(source.nameLengths[index])])
        var folded: [UInt8]?
        if source.foldStarts[index] != Self.sameAsRaw {
            let foldStart = Int(source.foldStarts[index])
            folded = Array(source.foldPool[foldStart..<foldStart + Int(source.foldLengths[index])])
        }
        let node = appendBytes(
            raw: raw, folded: folded, parent: parent, flags: source.flags[index].subtracting(.root),
            modified: source.modified[index])
        nextSibling[Int(node)] = firstChild[Int(parent)]
        firstChild[Int(parent)] = node
        liveCount += 1
        return node
    }

    private mutating func append(
        name: String, folded: [UInt8]?, parent: Int32, kind: EntryKind, modified: UInt32, root: Bool
    ) -> Int32 {
        var flags: Flags = root ? [.root] : []
        switch kind {
        case .directory: flags.insert(.directory)
        case .package: flags.insert(.package)
        case .symlink: flags.insert(.symlink)
        case .file: break
        }
        let raw = Array(name.utf8.prefix(Int(UInt16.max)))
        return appendBytes(raw: raw, folded: folded, parent: parent, flags: flags, modified: modified)
    }

    private mutating func appendBytes(
        raw: [UInt8], folded: [UInt8]?, parent: Int32, flags: Flags, modified: UInt32
    ) -> Int32 {
        let node = Int32(parents.count)
        parents.append(parent)
        firstChild.append(Self.none)
        nextSibling.append(Self.none)
        self.flags.append(flags)
        self.modified.append(modified)
        nameStarts.append(UInt32(namePool.count))
        nameLengths.append(UInt16(raw.count))
        namePool.append(contentsOf: raw)
        if let folded, folded != raw {
            let bytes = folded.prefix(Int(UInt16.max))
            foldStarts.append(UInt32(foldPool.count))
            foldLengths.append(UInt16(bytes.count))
            foldPool.append(contentsOf: bytes)
        } else {
            foldStarts.append(Self.sameAsRaw)
            foldLengths.append(0)
        }
        return node
    }

    private mutating func unlink(_ node: Int32, from parent: Int32) {
        var previous = Self.none
        var current = firstChild[Int(parent)]
        while current != Self.none {
            if current == node {
                if previous == Self.none {
                    firstChild[Int(parent)] = nextSibling[Int(current)]
                } else {
                    nextSibling[Int(previous)] = nextSibling[Int(current)]
                }
                return
            }
            previous = current
            current = nextSibling[Int(current)]
        }
    }

    private mutating func markRemoved(_ node: Int32) {
        var stack = [node]
        while let current = stack.popLast() {
            let index = Int(current)
            guard !flags[index].contains(.removed) else { continue }
            flags[index].insert(.removed)
            if flags[index].contains(.root) {
                roots.removeAll { $0 == current }
            } else {
                liveCount -= 1
            }
            removedCount += 1
            var child = firstChild[index]
            while child != Self.none {
                stack.append(child)
                child = nextSibling[Int(child)]
            }
            firstChild[index] = Self.none
        }
    }

    /// The normalised bytes of a name: ASCII is lowercased directly; anything else goes through
    /// `TextNormalizer`, so search matches exactly like the other sources.
    static func fold(_ name: String) -> [UInt8] {
        var bytes = Array(name.utf8)
        var ascii = true
        for index in bytes.indices {
            let byte = bytes[index]
            if byte >= 0x80 {
                ascii = false
                break
            }
            if byte >= 0x41, byte <= 0x5A {
                bytes[index] = byte + 0x20
            }
        }
        return ascii ? bytes : Array(TextNormalizer.normalize(name).utf8)
    }
}
