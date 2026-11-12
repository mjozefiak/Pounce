import Foundation

/// The optional names of the workspaces (`plugins.windows.workspaceNames`, window management v2, Phase 2): one
/// versioned JSON value `{"version": 1, "names": {"1": "Code", …}}`. A name has at most 24 characters and no control
/// or bidirectional-override characters; names need not be unique. They are the user's own words: never logged and
/// never sent through the string catalog. A value from a newer version, or one that does not parse, reads as no
/// names (a newer one is never overwritten).
struct WorkspaceNames: Equatable, Sendable {
    static let version = 1
    static let maximumLength = 24

    private(set) var names: [WorkspaceID: String] = [:]
    /// The stored value is from a newer version: nothing may be written over it.
    private(set) var isReadOnly = false

    init(_ names: [WorkspaceID: String] = [:]) {
        for (workspace, name) in names { if let clean = Self.clean(name) { self.names[workspace] = clean } }
    }

    private struct Record: Codable {
        var version: Int
        var names: [String: String]
    }

    init(json: String?) {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return }
        struct Header: Decodable { var version: Int }
        if let header = try? JSONDecoder().decode(Header.self, from: data), header.version > Self.version {
            isReadOnly = true
            return
        }
        guard let record = try? JSONDecoder().decode(Record.self, from: data), record.version >= 1 else { return }
        for (key, name) in record.names {
            if let number = Int(key), let workspace = WorkspaceID(number), let clean = Self.clean(name) {
                names[workspace] = clean
            }
        }
    }

    /// The JSON to store; no names give an empty string (the setting is then cleared).
    var json: String {
        guard !names.isEmpty else { return "" }
        let record = Record(
            version: Self.version,
            names: Dictionary(uniqueKeysWithValues: names.map { (String($0.key.rawValue), $0.value) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    func name(of workspace: WorkspaceID) -> String? { names[workspace] }

    mutating func set(_ name: String?, for workspace: WorkspaceID) {
        names[workspace] = name.flatMap(Self.clean)
    }

    /// "3 · Code" with a name, "3" without.
    func label(of workspace: WorkspaceID) -> String {
        guard let name = names[workspace] else { return String(workspace.rawValue) }
        return "\(workspace.rawValue) · \(name)"
    }

    /// The name made valid: control and bidirectional characters removed, surrounding space trimmed, cut to 24
    /// characters; `nil` when nothing is left.
    static func clean(_ raw: String) -> String? {
        let allowed = raw.unicodeScalars.filter { !isControlOrBidi($0) }
        var text = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maximumLength { text = String(text.prefix(maximumLength)) }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func isControlOrBidi(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F, 0x200E, 0x200F, 0x061C, 0x202A...0x202E, 0x2066...0x2069: true
        default: false
        }
    }
}
