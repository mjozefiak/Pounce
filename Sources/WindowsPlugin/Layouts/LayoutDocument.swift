import Foundation

/// A JSON value kept as it came, so a layout this build does not understand (a style from a newer version, the
/// reserved `canvas`) is written back unchanged.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

/// Why one layout record is not accepted (the single validator of `layouts.json` and of `.lintellayouts`).
enum LayoutRejection: Error, Equatable, Sendable {
    case badName
    case badID
    case badGrid(GridLayoutError)
    case malformed
}

/// The rules a layout must meet to be loaded, saved or imported (spec: Data Model, "Validation on load and before
/// save" and the import limits). Loading and import both go through `LayoutDocument.parse`, so there is one code
/// path.
enum LayoutRules {
    static let maximumNameLength = 64
    static let maximumIDLength = 128
    static let maximumLayouts = 256
    static let maximumFileSize = 1_048_576
    /// The newest `version` this build reads and writes (`layouts.json` and `.lintellayouts` share it).
    static let currentVersion = 1
    static let slotCount = 9
    static let userIDPrefix = "user."

    /// A control character or a bidirectional override or isolate: text that could change how the name reads.
    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return true
        default: break
        }
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }

    static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && name.count <= maximumNameLength && !name.unicodeScalars.contains(where: isForbidden)
    }

    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= maximumIDLength && !id.unicodeScalars.contains(where: isForbidden)
    }

    /// A user's layout may not use the id space of the stock templates.
    static func isValidUserID(_ id: String) -> Bool { isValidID(id) && !StockLayouts.isStock(id) }

    /// The grid layout a record describes, after every rule. A record of another style is not an error here (the
    /// caller keeps it untouched).
    /// `lenientIDs` (import) accepts any well-formed id, because the importer gives a new one to every id that
    /// collides or that a user layout may not have.
    static func check(_ record: LayoutRecord, lenientIDs: Bool = false) -> Result<GridLayout, LayoutRejection> {
        guard lenientIDs ? isValidID(record.id) : isValidUserID(record.id) else { return .failure(.badID) }
        guard isValidName(record.name) else { return .failure(.badName) }
        do {
            guard let layout = try record.gridLayout() else { return .failure(.malformed) }
            return .success(layout)
        } catch {
            return .failure(.badGrid(error))
        }
    }

    /// Checks a layout the app built (before it is saved).
    static func check(_ layout: GridLayout) -> LayoutRejection? {
        if case .failure(let rejection) = check(LayoutRecord(layout)) { return rejection }
        return nil
    }
}

/// One entry of a layout document.
enum LayoutEntry: Equatable, Sendable {
    /// A valid grid layout.
    case grid(GridLayout)
    /// Anything else, kept as it came: another style, or a grid record that breaks a rule. Never offered for
    /// assignment, never changed.
    case opaque(OpaqueLayout)

    var id: String? {
        switch self {
        case .grid(let layout): layout.id
        case .opaque(let opaque): opaque.id
        }
    }
}

struct OpaqueLayout: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case unknownStyle
        case invalid(LayoutRejection)
    }

    var raw: JSONValue
    var reason: Reason

    var id: String? { raw.objectValue?["id"]?.stringValue }
}

/// A parsed `layouts.json` or `.lintellayouts` file.
struct LayoutDocument: Equatable, Sendable {
    enum ParseError: Error, Equatable, Sendable {
        case tooLarge
        case malformed
        case tooManyLayouts
    }

    var version: Int
    var entries: [LayoutEntry]
    /// Slot number to layout id (`layouts.json` only; an import never reads it).
    var slots: [Int: String]

    private struct Raw: Decodable {
        var version: Int
        var layouts: [JSONValue]
        var slots: [String: String]?
    }

    /// Parses a document. With `enforceFileLimits` (import) the size and the layout count are limited too.
    static func parse(_ data: Data, enforceFileLimits: Bool = false) throws(ParseError) -> LayoutDocument {
        try parse(data, enforceFileLimits: enforceFileLimits, lenientIDs: false)
    }

    static func parse(
        _ data: Data, enforceFileLimits: Bool, lenientIDs: Bool
    ) throws(ParseError) -> LayoutDocument {
        if enforceFileLimits, data.count > LayoutRules.maximumFileSize { throw .tooLarge }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { throw .malformed }
        guard raw.version >= 1 else { throw .malformed }
        if enforceFileLimits, raw.layouts.count > LayoutRules.maximumLayouts { throw .tooManyLayouts }
        var entries: [LayoutEntry] = []
        entries.reserveCapacity(raw.layouts.count)
        for value in raw.layouts { entries.append(classify(value, lenientIDs: lenientIDs)) }
        var slots: [Int: String] = [:]
        for (key, id) in raw.slots ?? [:] {
            if let number = Int(key), (1...LayoutRules.slotCount).contains(number) { slots[number] = id }
        }
        return LayoutDocument(version: raw.version, entries: entries, slots: slots)
    }

    private static func classify(_ value: JSONValue, lenientIDs: Bool) -> LayoutEntry {
        guard let object = value.objectValue, let style = object["style"]?.stringValue else {
            return .opaque(OpaqueLayout(raw: value, reason: .invalid(.malformed)))
        }
        guard style == LayoutRecord.gridStyle else {
            return .opaque(OpaqueLayout(raw: value, reason: .unknownStyle))
        }
        guard let data = try? JSONEncoder().encode(value),
            let record = try? JSONDecoder().decode(LayoutRecord.self, from: data)
        else { return .opaque(OpaqueLayout(raw: value, reason: .invalid(.malformed))) }
        switch LayoutRules.check(record, lenientIDs: lenientIDs) {
        case .success(let layout): return .grid(layout)
        case .failure(let rejection): return .opaque(OpaqueLayout(raw: value, reason: .invalid(rejection)))
        }
    }

    // MARK: Writing

    private struct Out: Encodable {
        var version: Int
        var layouts: [Item]
        var slots: [String: String]?

        enum Item: Encodable {
            case record(LayoutRecord)
            case raw(JSONValue)

            func encode(to encoder: Encoder) throws {
                switch self {
                case .record(let record): try record.encode(to: encoder)
                case .raw(let value): try value.encode(to: encoder)
                }
            }
        }
    }

    /// The file's bytes: stable key order, grid layouts re-encoded, opaque ones written as they came.
    func encoded() throws -> Data {
        let items: [Out.Item] = entries.map {
            switch $0 {
            case .grid(let layout): .record(LayoutRecord(layout))
            case .opaque(let opaque): .raw(opaque.raw)
            }
        }
        var named: [String: String] = [:]
        for (number, id) in slots { named[String(number)] = id }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Out(version: version, layouts: items, slots: named.isEmpty ? nil : named))
    }

    var gridLayouts: [GridLayout] {
        entries.compactMap {
            if case .grid(let layout) = $0 { layout } else { nil }
        }
    }
}
