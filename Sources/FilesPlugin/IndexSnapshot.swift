import Foundation
import PouncePersistence

/// The saved index, `Plugins/files/index.snapshot` (spec: Data Model, step 3.5).
///
/// Layout: the magic `PNCEIDX\0`, `schema_version` (UInt32, little endian), then an LZFSE-compressed
/// payload: `complete`, `last_event_id`, the plan fingerprint, the roots with the FSEvents device UUID of
/// each, and the nodes in index order (parent, flags, mtime, raw name, normalised name when it differs).
/// A node's parent always comes before it, so loading rebuilds the tree in one pass and rejects anything
/// else. The file is not encrypted (a deliberate spec decision: mode 0600 and FileVault protect it, and a
/// scan rebuilds it).
struct IndexSnapshot: Sendable {
    static let fileName = "index.snapshot"
    static let magic: [UInt8] = Array("PNCEIDX".utf8) + [0]
    static let schemaVersion: UInt32 = 1

    struct Root: Hashable, Sendable {
        let path: String
        /// `FSEventsCopyUUIDForDevice` of the root's volume; empty when unknown.
        let deviceUUID: String
    }

    /// Whether the scan that produced it finished (`false` for the partial saves during the first scan).
    var complete: Bool
    /// The FSEvents id up to which the index is up to date.
    var lastEventID: UInt64
    var fingerprint: String
    var roots: [Root]
    var store: NameStore

    enum LoadError: Error, Equatable {
        case missing
        case unknownVersion(UInt32)
        case damaged
    }

    // MARK: Encoding

    func encoded() throws -> Data {
        var writer = ByteWriter()
        writer.byte(complete ? 1 : 0)
        writer.uint64(lastEventID)
        writer.string(fingerprint)
        writer.uint32(UInt32(roots.count))
        for root in roots {
            writer.string(root.path)
            writer.string(root.deviceUUID)
        }
        let compact = store.removedCount == 0 ? store : store.compacted()
        writer.uint32(UInt32(compact.nodeCount))
        for node in 0..<compact.nodeCount {
            writer.int32(compact.parents[node])
            writer.byte(compact.flags[node].rawValue)
            writer.uint32(compact.modified[node])
            let rawStart = Int(compact.nameStarts[node])
            writer.bytes(compact.namePool[rawStart..<rawStart + Int(compact.nameLengths[node])])
            if compact.foldStarts[node] == NameStore.sameAsRaw {
                writer.uint16(UInt16.max)
            } else {
                let foldStart = Int(compact.foldStarts[node])
                writer.bytes(compact.foldPool[foldStart..<foldStart + Int(compact.foldLengths[node])])
            }
        }
        let compressed = try (Data(writer.data) as NSData).compressed(using: .lzfse) as Data
        var file = Data(Self.magic)
        withUnsafeBytes(of: Self.schemaVersion.littleEndian) { file.append(contentsOf: $0) }
        file.append(compressed)
        return file
    }

    static func decode(_ data: Data) throws(LoadError) -> IndexSnapshot {
        guard data.count >= magic.count + 4, Array(data.prefix(magic.count)) == magic else { throw .damaged }
        var version: UInt32 = 0
        for (shift, byte) in data.dropFirst(magic.count).prefix(4).enumerated() {
            version |= UInt32(byte) << (8 * UInt32(shift))
        }
        guard version == schemaVersion else { throw .unknownVersion(version) }
        let body = data.dropFirst(magic.count + 4)
        guard let payload = try? (Data(body) as NSData).decompressed(using: .lzfse) as Data else { throw .damaged }
        var reader = ByteReader(Array(payload))
        guard let complete = reader.byte(), let lastEventID = reader.uint64(), let fingerprint = reader.string(),
            let rootCount = reader.uint32(), rootCount < 10_000
        else { throw .damaged }
        var roots: [Root] = []
        for _ in 0..<rootCount {
            guard let path = reader.string(), let uuid = reader.string() else { throw .damaged }
            roots.append(Root(path: path, deviceUUID: uuid))
        }
        guard let nodeCount = reader.uint32() else { throw .damaged }
        var store = NameStore()
        store.reserve(Int(min(nodeCount, 50_000_000)), nameBytes: 0, foldBytes: 0)
        for index in 0..<Int(nodeCount) {
            guard let parent = reader.int32(), let rawFlags = reader.byte(), let modified = reader.uint32(),
                let raw = reader.bytes()
            else { throw .damaged }
            let folded: [UInt8]?
            if reader.peekSameAsRaw() {
                folded = nil
            } else {
                guard let bytes = reader.bytes() else { throw .damaged }
                folded = bytes
            }
            let flags = NameStore.Flags(rawValue: rawFlags)
            guard !flags.contains(.removed), Int(parent) < index, parent >= NameStore.none,
                (parent == NameStore.none) == flags.contains(.root),
                parent == NameStore.none || store.isLive(parent)
            else { throw .damaged }
            store.appendLoaded(raw: raw, folded: folded, parent: parent, flags: flags, modified: modified)
        }
        guard reader.isAtEnd else { throw .damaged }
        return IndexSnapshot(
            complete: complete == 1, lastEventID: lastEventID, fingerprint: fingerprint, roots: roots, store: store)
    }

    // MARK: Files

    static func url(in directory: URL) -> URL {
        directory.appending(path: fileName)
    }

    /// Writes atomically (temporary file, then `rename`) with mode 0600.
    func save(in directory: URL) throws {
        try AtomicFile.write(try encoded(), to: Self.url(in: directory))
    }

    static func load(from directory: URL) throws(LoadError) -> IndexSnapshot {
        guard let data = try? Data(contentsOf: url(in: directory), options: .mappedIfSafe) else { throw .missing }
        return try decode(data)
    }

    static func delete(in directory: URL) {
        try? FileManager.default.removeItem(at: url(in: directory))
    }
}

extension NameStore {
    /// Appends a node read from a snapshot (the caller validated the parent).
    mutating func appendLoaded(raw: [UInt8], folded: [UInt8]?, parent: Int32, flags: Flags, modified: UInt32) {
        let node: Int32
        if flags.contains(.root) {
            node = addRoot(path: String(decoding: raw, as: UTF8.self), kind: Self.kind(of: flags), modified: modified)
        } else {
            node = addChild(raw: raw, folded: folded ?? raw, flags: flags, modified: modified, parent: parent)
        }
        _ = node
    }

    static func kind(of flags: Flags) -> EntryKind {
        if flags.contains(.package) { return .package }
        if flags.contains(.directory) { return .directory }
        if flags.contains(.symlink) { return .symlink }
        return .file
    }
}

/// Little-endian binary writer.
private struct ByteWriter {
    var data: [UInt8] = []

    mutating func byte(_ value: UInt8) { data.append(value) }
    mutating func uint16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func uint32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func int32(_ value: Int32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func uint64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

    /// A length (UInt16, below `UInt16.max`) and the bytes.
    mutating func bytes(_ value: ArraySlice<UInt8>) {
        let count = min(value.count, Int(UInt16.max) - 1)
        uint16(UInt16(count))
        data.append(contentsOf: value.prefix(count))
    }

    mutating func string(_ value: String) {
        let utf8 = Array(value.utf8)
        uint32(UInt32(utf8.count))
        data.append(contentsOf: utf8)
    }
}

/// Little-endian binary reader that returns `nil` instead of reading past the end.
private struct ByteReader {
    private let data: [UInt8]
    private var offset = 0

    init(_ data: [UInt8]) {
        self.data = data
    }

    var isAtEnd: Bool { offset == data.count }

    private mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
        guard count >= 0, offset + count <= data.count else { return nil }
        defer { offset += count }
        return data[offset..<offset + count]
    }

    private mutating func integer<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        guard let bytes = take(MemoryLayout<T>.size) else { return nil }
        var value: T = 0
        for (shift, byte) in bytes.enumerated() {
            value |= T(truncatingIfNeeded: byte) << (8 * shift)
        }
        return value
    }

    mutating func byte() -> UInt8? { take(1)?.first }
    mutating func uint32() -> UInt32? { integer(UInt32.self) }
    mutating func int32() -> Int32? { integer(Int32.self) }
    mutating func uint64() -> UInt64? { integer(UInt64.self) }

    /// Consumes the `UInt16.max` marker for "normalised name equals the raw name" when it is next.
    mutating func peekSameAsRaw() -> Bool {
        guard offset + 2 <= data.count, data[offset] == 0xFF, data[offset + 1] == 0xFF else { return false }
        offset += 2
        return true
    }

    mutating func bytes() -> [UInt8]? {
        guard let count = integer(UInt16.self), count != UInt16.max, let bytes = take(Int(count)) else { return nil }
        return Array(bytes)
    }

    mutating func string() -> String? {
        guard let count = uint32(), count < 1 << 24, let bytes = take(Int(count)) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
