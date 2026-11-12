import AppKit
import Foundation

/// The Rules section of the Configure window (window management v2, Phase 3): one list made of the floating apps
/// (`plugins.windows.floatingApps`, the v1 contract) and the workspace rules (`plugins.windows.appRules`). An app has
/// one entry: float wins, and the window cannot add a second.
extension WindowsConfigureModel {
    enum RuleChoice: Hashable {
        case float
        case workspace(Int)

        /// The picker's tag.
        var tag: String {
            switch self {
            case .float: "float"
            case .workspace(let number): "ws\(number)"
            }
        }

        init?(tag: String) {
            if tag == "float" {
                self = .float
            } else if tag.hasPrefix("ws"), let number = Int(tag.dropFirst(2)),
                (WindowsSettings.minimumWorkspaces...WindowsSettings.maximumWorkspaces).contains(number)
            {
                self = .workspace(number)
            } else {
                return nil
            }
        }
    }

    struct RuleRow: Identifiable, Equatable {
        var bundleID: String
        var name: String
        var choice: RuleChoice
        /// "Workspace 8 is off": the rule is kept but does not apply while the workspace does not exist.
        var isInactive: Bool

        var id: String { bundleID }
    }

    var rulesLocked: Bool { pane.settings.appRules.isReadOnly }

    var ruleRows: [RuleRow] {
        let rules = pane.settings.appRules
        let floating = pane.floatingApps
        var rows = floating.map {
            RuleRow(bundleID: $0, name: pane.appName($0), choice: .float, isInactive: false)
        }
        for entry in rules.entries where !floating.contains(entry.bundleID) {
            rows.append(
                RuleRow(
                    bundleID: entry.bundleID, name: pane.appName(entry.bundleID), choice: .workspace(entry.workspace),
                    isInactive: entry.workspace > pane.workspaceCount))
        }
        return rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Adds an app with an action; an app that already has a rule is refused (change its action instead).
    @discardableResult
    func addRule(bundleID: String, _ choice: RuleChoice) -> Bool {
        guard !ruleRows.contains(where: { $0.bundleID == bundleID }), !rulesLocked || choice == .float else {
            return false
        }
        apply(choice, to: bundleID)
        return true
    }

    func setRule(_ choice: RuleChoice, for bundleID: String) {
        guard ruleRows.contains(where: { $0.bundleID == bundleID }), !rulesLocked || choice == .float else { return }
        apply(choice, to: bundleID)
    }

    func removeRule(_ bundleID: String) {
        pane.setFloating(bundleID, false)
        var rules = pane.settings.appRules
        guard !rules.isReadOnly else { return }
        rules.set(bundleID: bundleID, workspace: nil)
        pane.setAppRules(rules)
    }

    private func apply(_ choice: RuleChoice, to bundleID: String) {
        var rules = pane.settings.appRules
        switch choice {
        case .float:
            if !rules.isReadOnly {
                rules.set(bundleID: bundleID, workspace: nil)
                pane.setAppRules(rules)
            }
            pane.setFloating(bundleID, true)
        case .workspace(let number):
            pane.setFloating(bundleID, false)
            rules.set(bundleID: bundleID, workspace: number)
            pane.setAppRules(rules)
        }
    }

    /// The apps to pick from: the running ones with a Dock icon (a bundle id and a name), without those that
    /// already have a rule. The *Choose…* button covers the rest of /Applications.
    func appCandidates() -> [(bundleID: String, name: String)] {
        let taken = Set(ruleRows.map(\.bundleID))
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> (String, String)? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, !taken.contains(id),
                let name = app.localizedName
            else { return nil }
            return (id, name)
        }
        return apps.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            .map { (bundleID: $0.0, name: $0.1) }
    }
}
