import Foundation

/// What a rule does with the windows of an app (window management v2, Phase 3).
enum AppRule: Equatable, Sendable {
    /// Never arranged (the floating list, `plugins.windows.floatingApps`).
    case float
    /// New windows of the app start on this workspace.
    case workspace(WorkspaceID)
}

/// The workspace assignments of `plugins.windows.appRules`: one versioned JSON value
/// `{"version": 1, "rules": [{"bundleID": "...", "workspace": 3}]}`. A `float` rule is not stored here: it stays in
/// `plugins.windows.floatingApps`, the v1 contract. A rule with a workspace outside 1 to 9 or a bundle id longer than
/// 255 characters is dropped; a repeated bundle id keeps the last entry when read. A value from a newer version, or
/// one that does not parse, reads as no rules (a newer one is never overwritten). Bundle ids are never logged.
struct AppRules: Equatable, Sendable {
    static let version = 1
    static let maximumBundleIDLength = 255

    struct Entry: Equatable, Sendable, Codable {
        var bundleID: String
        var workspace: Int
    }

    private(set) var entries: [Entry] = []
    private(set) var isReadOnly = false

    init(_ entries: [Entry] = []) {
        var seen: [String: Int] = [:]
        for entry in entries where Self.isValid(entry) {
            if let index = seen[entry.bundleID] {
                // Written from the interface the first one wins: the later duplicate is the one dropped there;
                // here (read) the last one wins.
                self.entries[index] = entry
            } else {
                seen[entry.bundleID] = self.entries.count
                self.entries.append(entry)
            }
        }
    }

    private struct Record: Codable {
        var version: Int
        var rules: [Entry]
    }

    init(json: String?) {
        self.init()
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return }
        struct Header: Decodable { var version: Int }
        if let header = try? JSONDecoder().decode(Header.self, from: data), header.version > Self.version {
            isReadOnly = true
            return
        }
        guard let record = try? JSONDecoder().decode(Record.self, from: data), record.version >= 1 else { return }
        self = AppRules(record.rules)
    }

    var json: String {
        guard !entries.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Record(version: Self.version, rules: entries)),
            let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    static func isValid(_ entry: Entry) -> Bool {
        !entry.bundleID.isEmpty && entry.bundleID.count <= maximumBundleIDLength
            && (WindowsSettings.minimumWorkspaces...WindowsSettings.maximumWorkspaces).contains(entry.workspace)
    }

    func workspace(of bundleID: String) -> Int? { entries.first { $0.bundleID == bundleID }?.workspace }

    /// Adds or changes the rule of an app (the interface keeps one entry per app; an invalid one is refused).
    mutating func set(bundleID: String, workspace: Int?) {
        entries.removeAll { $0.bundleID == bundleID }
        guard let workspace else { return }
        let entry = Entry(bundleID: bundleID, workspace: workspace)
        if Self.isValid(entry) { entries.append(entry) }
    }
}

/// Which rule applies to an app: the one function the engine configuration and the Configure window share.
enum RuleResolver {
    /// Float wins over a workspace rule (one app, one entry); a workspace rule for a workspace that is off (more than
    /// `workspaceCount`) is kept in the settings but does not apply, so the window stays where it opens.
    static func resolve(bundleID: String, floating: Set<String>, rules: AppRules, workspaceCount: Int) -> AppRule? {
        if floating.contains(bundleID) { return .float }
        guard let number = rules.workspace(of: bundleID), number <= workspaceCount,
            let workspace = WorkspaceID(number)
        else { return nil }
        return .workspace(workspace)
    }

    /// The workspace of every app with an active workspace rule, for the engine.
    static func assignments(floating: Set<String>, rules: AppRules, workspaceCount: Int) -> [String: WorkspaceID] {
        var result: [String: WorkspaceID] = [:]
        for entry in rules.entries {
            if case .workspace(let workspace)? = resolve(
                bundleID: entry.bundleID, floating: floating, rules: rules, workspaceCount: workspaceCount)
            {
                result[entry.bundleID] = workspace
            }
        }
        return result
    }
}
