import AppKit
import LintelKit
import LintelUI
import SwiftUI

/// One permission the enabled plugins need, with the names of the plugins that ask for it.
struct PermissionRequirement: Identifiable, Equatable {
    let permission: Permission
    /// Display names of the enabled plugins that need it, in plugin order.
    let pluginNames: [String]

    var id: Permission { permission }
}

/// What Settings → Permissions shows and does (spec step 4.1), kept out of the view so it is tested.
///
/// The rows are the union of `requiredPermissions` of the **enabled** plugins (a failed plugin still
/// counts: turning it off is how the user stops it asking). States come from the same preflight-only
/// `PermissionsReader` the plugins use, so reading them never shows a system prompt.
@Observable
final class PermissionsModel {
    @ObservationIgnored let host: PluginHost
    @ObservationIgnored private let reader: any PermissionsReader
    @ObservationIgnored private let openURL: (URL) -> Void
    @ObservationIgnored private let requester: any PermissionRequester

    /// The last read state of each required permission; refreshed by `refresh()`.
    private(set) var statuses: [Permission: PermissionStatus] = [:]

    init(
        host: PluginHost, reader: any PermissionsReader,
        requester: any PermissionRequester = SystemPermissionRequester(),
        openURL: @escaping (URL) -> Void
    ) {
        self.host = host
        self.reader = reader
        self.requester = requester
        self.openURL = openURL
    }

    /// The rows to draw, one per permission in `Permission.allCases` order; the ones no enabled feature needs are
    /// dimmed (spec D5).
    var rows: [PermissionRowState] {
        let required = Dictionary(uniqueKeysWithValues: requirements.map { ($0.permission, $0.pluginNames) })
        return Permission.allCases.map { permission in
            PermissionRowState(
                permission: permission, status: status(of: permission), pluginNames: required[permission] ?? [])
        }
    }

    /// "Allow Microphone": the user's click, so the system prompt may appear. Reads the states again after.
    func allow(_ permission: Permission) async {
        await requester.request(permission)
        refresh()
    }

    /// The permissions of the enabled plugins, in `Permission.allCases` order.
    var requirements: [PermissionRequirement] {
        let enabled = host.entries.filter { host.isEnabled($0.manifest.id) }
        return Permission.allCases.compactMap { permission in
            let names = enabled.filter { $0.plugin.requiredPermissions.contains(permission) }
                .map { String(localized: $0.manifest.displayName) }
            return names.isEmpty ? nil : PermissionRequirement(permission: permission, pluginNames: names)
        }
    }

    /// The controls the enabled plugins that need `permission` offer under its row (a "Test" button).
    func accessories(for permission: Permission) -> [AnyView] {
        host.entries.filter { host.isEnabled($0.manifest.id) && $0.plugin.requiredPermissions.contains(permission) }
            .compactMap { $0.plugin.permissionAccessory(for: permission) }
    }

    func status(of permission: Permission) -> PermissionStatus {
        // A model that has not refreshed yet (the host rebuilt it) still answers with the real state: the reader
        // only preflights, so reading it here never shows a prompt.
        statuses[permission] ?? (permission.isReadable ? reader.status(of: permission) : .notDetermined)
    }

    /// Re-reads every readable permission ("Check Again", the pane appearing, Lintel becoming active).
    func refresh() {
        var result: [Permission: PermissionStatus] = [:]
        for permission in Permission.allCases where permission.isReadable {
            result[permission] = reader.status(of: permission)
        }
        statuses = result
    }

    /// Opens the permission's page in System Settings.
    func openSettings(for permission: Permission) {
        openURL(permission.settingsURL)
    }
}

extension Permission {
    /// The permission's page in System Settings → Privacy & Security.
    var settingsURL: URL {
        let anchor =
            switch self {
            case .accessibility: "?Privacy_Accessibility"
            case .fullDiskAccess: "?Privacy_AllFiles"
            // The pasteboard setting has no documented anchor: open Privacy & Security itself.
            case .pasteboard: ""
            case .microphone: "?Privacy_Microphone"
            // Unconfirmed: the System Audio Recording pane id is a manual test item (ADR 0007, item 4).
            // If it does not exist, System Settings still opens on Privacy & Security.
            case .systemAudioRecording: "?Privacy_AudioCapture"
            }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security" + anchor)
            ?? URL(filePath: "/System/Applications/System Settings.app")
    }

    var title: String {
        switch self {
        case .accessibility:
            String(localized: "Accessibility", comment: "Permission name in Settings → Permissions")
        case .fullDiskAccess:
            String(localized: "Full Disk Access", comment: "Permission name in Settings → Permissions")
        case .pasteboard:
            String(localized: "Clipboard Access", comment: "Permission name in Settings → Permissions")
        case .microphone:
            String(localized: "Microphone", comment: "Permission name in Settings → Permissions")
        case .systemAudioRecording:
            String(localized: "System Audio Recording", comment: "Permission name in Settings → Permissions")
        }
    }

    var explanation: String {
        switch self {
        case .accessibility:
            String(
                localized: "Lets Lintel paste into the app you were using. Without it, Lintel only copies.",
                comment: "Explanation of the Accessibility permission")
        case .fullDiskAccess:
            String(
                localized:
                    "Lets file search include Desktop, Documents, Downloads and iCloud Drive without asking about each folder.",
                comment: "Explanation of the Full Disk Access permission")
        case .pasteboard:
            String(
                localized:
                    "macOS can ask before an app reads the clipboard. Allow Lintel so the history keeps recording.",
                comment: "Explanation of the clipboard access permission")
        case .microphone:
            String(
                localized:
                    "Lets Lintel hear you while you dictate or record a meeting. Dictation audio is never saved; meeting audio is stored encrypted on this Mac until the transcript is complete, and the audio of unfinished meetings is kept for a limited time.",
                comment: "Explanation of the Microphone permission")
        case .systemAudioRecording:
            String(
                localized:
                    "Lets Lintel capture what other people say in a meeting, only while a meeting is recorded. Audio is processed on this Mac and never uploaded.",
                comment: "Explanation of the System Audio Recording permission")
        }
    }

    /// The state in words, so it never depends on the symbol's colour.
    func statusText(_ status: PermissionStatus) -> String {
        switch (self, status) {
        case (.systemAudioRecording, .notDetermined):
            // macOS cannot report this permission, so this is not a denial.
            String(localized: "Can't be checked", comment: "System Audio Recording state: macOS does not tell apps")
        case (.pasteboard, .granted):
            String(localized: "Always allowed", comment: "Clipboard access state")
        case (.pasteboard, .denied):
            String(localized: "Denied", comment: "Clipboard access state")
        case (.pasteboard, .notDetermined):
            String(localized: "Asks or follows the system default", comment: "Clipboard access state")
        case (_, .granted):
            String(localized: "Allowed", comment: "Permission state")
        case (_, .denied):
            String(localized: "Not allowed", comment: "Permission state")
        case (_, .notDetermined):
            String(localized: "Unknown", comment: "Permission state")
        }
    }
}

/// How a permission row reads: a state in words, never colour alone.
enum PermissionTone: Equatable {
    case ok
    /// A readable permission the user has refused.
    case problem
    /// Not granted yet, or macOS cannot report it (System Audio Recording): never a problem.
    case neutral
}

/// What one `PermissionRow` shows, kept out of the view so it is tested.
struct PermissionRowState: Identifiable, Equatable {
    let permission: Permission
    let status: PermissionStatus
    /// Display names of the enabled plugins that need it; empty when no enabled feature does.
    let pluginNames: [String]

    var id: Permission { permission }
    /// No enabled feature needs it: the row is dimmed.
    var isDimmed: Bool { pluginNames.isEmpty }
    var stateText: String { permission.statusText(status) }

    /// The state line of the row: "Not asked yet" where `stateText` says "Unknown".
    var mainStateText: String {
        guard permission.isReadable, permission != .pasteboard, status == .notDetermined else { return stateText }
        return String(localized: "Not asked yet", comment: "Permission state: macOS has not asked the user yet")
    }

    /// Row order: permissions that need the user first (denied, not asked), then the allowed ones, then
    /// the ones no enabled feature needs. Stable inside each group.
    static func problemsFirst(_ rows: [PermissionRowState]) -> [PermissionRowState] {
        func rank(_ row: PermissionRowState) -> Int { row.isDimmed ? 2 : (row.tone == .ok ? 1 : 0) }
        return rows.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    var tone: PermissionTone {
        guard permission.isReadable else { return .neutral }
        switch status {
        case .granted: return .ok
        case .denied: return .problem
        case .notDetermined: return .neutral
        }
    }

    /// "Allow Microphone" while macOS has not asked yet; every other state goes through System Settings.
    var allowTitle: String? {
        guard permission == .microphone, status == .notDetermined else { return nil }
        return String(localized: "Allow Microphone", comment: "Button that asks for microphone access")
    }
}

/// Settings → Permissions: a row per permission with its state and a button to its page in System Settings.
/// Every permission is listed; the ones no enabled feature needs are dimmed (spec D5).
struct PermissionsPane: View {
    /// Kept in `@State`: `SettingsHost` builds the pane again whenever its own state changes, and a new model
    /// would start with no states.
    @State private var model: PermissionsModel

    init(model: PermissionsModel) {
        _model = State(initialValue: model)
    }

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        mainForm
            .onAppear { model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                model.refresh()
            }
    }

    /// No section header (the host's title names the pane), problems first, one footer.
    private var mainForm: some View {
        SettingsPane {
            Section {
                let rows = PermissionRowState.problemsFirst(model.rows)
                if rows.isEmpty {
                    emptyText
                }
                ForEach(rows) { row in
                    PermissionRow(
                        state: row,
                        accessories: model.accessories(for: row.permission),
                        allow: { Task { await model.allow(row.permission) } },
                        open: { model.openSettings(for: row.permission) }
                    )
                }
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    SettingsFooter(
                        "Lintel never asks for a permission on its own. Changes in System Settings apply right away."
                    )
                    Spacer()
                    checkAgain
                }
            }
        }
    }

    private var emptyText: some View {
        Text(
            "The features that are on need no system permissions.",
            comment: "Settings → Permissions when no enabled feature needs a permission"
        )
        .font(textSize.font(.body))
        .foregroundStyle(LintelBrand.secondaryText)
    }

    private var checkAgain: some View {
        Button {
            model.refresh()
        } label: {
            Text("Check Again", comment: "Button that re-reads the permission states")
        }
    }
}
