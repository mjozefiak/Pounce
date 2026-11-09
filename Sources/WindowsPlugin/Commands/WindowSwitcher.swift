import Foundation
import LintelCore
import LintelKit

/// A window as the switcher shows it. The title lives in memory only (spec: Data Model).
struct SwitcherWindow: Sendable, Equatable {
    var id: WindowID
    var title: String
    var bundleID: String?
    var workspace: WorkspaceID?
}

struct SwitcherSnapshot: Sendable, Equatable {
    var workspaces: [(workspace: WorkspaceID, windowCount: Int)]
    var windows: [SwitcherWindow]

    static func == (lhs: SwitcherSnapshot, rhs: SwitcherSnapshot) -> Bool {
        lhs.windows == rhs.windows && lhs.workspaces.map(\.workspace) == rhs.workspaces.map(\.workspace)
            && lhs.workspaces.map(\.windowCount) == rhs.workspaces.map(\.windowCount)
    }
}

/// What the switcher asks of the running plugin. The plugin's runtime implements it over the engine; a test
/// implements it with a fake.
protocol WindowSwitching: Sendable {
    func snapshot() async -> SwitcherSnapshot
    func goToWorkspace(_ workspace: WorkspaceID) async
    func goToWindow(_ id: WindowID) async
    func bringHere(_ id: WindowID) async
}

/// The launcher's window switcher (spec Q13, source `windows.windows`): lists workspaces and windows that match
/// the query. Return goes to the window, ⌘Return brings it to the current workspace. Results are never ranked or
/// recorded: this source has no usage recorder at all, and nothing it returns carries a usage key beyond the
/// shell's own item key (`windows:<pid>.<number>`).
struct WindowSearchSource: SearchSource {
    let id: SourceID = "windows.windows"
    let switcher: any WindowSwitching

    static let pluginID = WindowsPlugin.manifest.id

    static func itemKey(_ id: WindowID) -> ItemKey { ItemKey(pluginID: pluginID, key: "\(id.pid).\(id.number)") }
    static func itemKey(_ workspace: WorkspaceID) -> ItemKey {
        ItemKey(pluginID: pluginID, key: "ws.\(workspace.rawValue)")
    }

    enum Target: Equatable {
        case window(WindowID)
        case workspace(WorkspaceID)

        init?(_ key: ItemKey) {
            guard key.pluginID == WindowSearchSource.pluginID else { return nil }
            if key.key.hasPrefix("ws."), let number = Int(key.key.dropFirst(3)), let workspace = WorkspaceID(number) {
                self = .workspace(workspace)
            } else {
                let parts = key.key.split(separator: ".")
                guard parts.count == 2, let pid = Int32(parts[0]), let number = UInt32(parts[1]) else { return nil }
                self = .window(WindowID(pid: pid, number: number))
            }
        }
    }

    func search(_ query: NormalizedQuery, limit: Int) async throws -> [Candidate] {
        guard !query.isEmpty else { return [] }
        let snapshot = await switcher.snapshot()
        try Task.checkCancellation()
        let scalars = Array(query.normalized.unicodeScalars)
        var candidates: [Candidate] = []
        for entry in snapshot.workspaces {
            let title = String(
                localized: "Workspace \(entry.workspace.rawValue)", comment: "Window switcher: a workspace")
            guard let match = FuzzyMatcher.match(scalars, in: NormalizedText(title)) else { continue }
            candidates.append(
                Candidate(
                    itemKey: Self.itemKey(entry.workspace), title: title,
                    subtitle: Self.windowCount(entry.windowCount), icon: .symbol("rectangle.3.group"), match: match))
        }
        for window in snapshot.windows where !window.title.isEmpty {
            guard let match = FuzzyMatcher.match(scalars, in: NormalizedText(window.title)) else { continue }
            candidates.append(
                Candidate(
                    itemKey: Self.itemKey(window.id), title: window.title,
                    subtitle: window.workspace.map {
                        String(localized: "Workspace \($0.rawValue)", comment: "Window switcher: a workspace")
                    },
                    icon: window.bundleID.map(IconRef.bundleIdentifier) ?? .symbol("macwindow"), match: match))
        }
        candidates.sort {
            if $0.match.tier != $1.match.tier { return $0.match.tier < $1.match.tier }
            if $0.match.score != $1.match.score { return $0.match.score > $1.match.score }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        return Array(candidates.prefix(limit))
    }

    static func windowCount(_ count: Int) -> String {
        count == 0
            ? String(localized: "No windows", comment: "Window HUD and switcher: an empty workspace")
            : String(
                localized: "\(count) windows", comment: "Window HUD and switcher: how many windows a workspace holds")
    }

    func actions(for candidate: Candidate) -> [ResultAction] {
        guard let target = Target(candidate.itemKey) else { return [] }
        let switcher = switcher
        switch target {
        case .workspace(let workspace):
            return [
                ResultAction(
                    id: "windows.goToWorkspace",
                    title: LocalizedStringResource("Go to Workspace", comment: "Action: switches to a workspace"),
                    symbolName: "arrow.right.circle",
                    perform: { _ in await switcher.goToWorkspace(workspace) })
            ]
        case .window(let id):
            return [
                ResultAction(
                    id: "windows.goToWindow",
                    title: LocalizedStringResource(
                        "Go to Window", comment: "Action: switches to a window's workspace and focuses it"),
                    symbolName: "arrow.right.circle",
                    perform: { _ in await switcher.goToWindow(id) }),
                ResultAction(
                    id: "windows.bringHere",
                    title: LocalizedStringResource(
                        "Bring to This Workspace", comment: "Action: moves a window to the current workspace"),
                    symbolName: "arrow.down.right.and.arrow.up.left",
                    shortcut: KeyShortcut(key: "\r", modifiers: [.command]),
                    perform: { _ in await switcher.bringHere(id) }),
            ]
        }
    }
}
