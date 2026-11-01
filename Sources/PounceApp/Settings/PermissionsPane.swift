import AppKit
import PounceKit
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
    @ObservationIgnored private let host: PluginHost
    @ObservationIgnored private let reader: any PermissionsReader
    @ObservationIgnored private let openURL: (URL) -> Void

    /// The last read state of each required permission; refreshed by `refresh()`.
    private(set) var statuses: [Permission: PermissionStatus] = [:]

    init(host: PluginHost, reader: any PermissionsReader, openURL: @escaping (URL) -> Void) {
        self.host = host
        self.reader = reader
        self.openURL = openURL
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

    func status(of permission: Permission) -> PermissionStatus {
        statuses[permission] ?? .notDetermined
    }

    /// Re-reads every required permission ("Check Again", the pane appearing, Pounce becoming active).
    func refresh() {
        var result: [Permission: PermissionStatus] = [:]
        for requirement in requirements {
            result[requirement.permission] = reader.status(of: requirement.permission)
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
            }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security" + anchor)
            ?? URL(filePath: "/System/Applications/System Settings.app")
    }

    var symbolName: String {
        switch self {
        case .accessibility: "accessibility"
        case .fullDiskAccess: "externaldrive"
        case .pasteboard: "doc.on.clipboard"
        }
    }

    var title: String {
        switch self {
        case .accessibility:
            String(localized: "Accessibility", comment: "Permission name in Settings → Permissions")
        case .fullDiskAccess:
            String(localized: "Full Disk Access", comment: "Permission name in Settings → Permissions")
        case .pasteboard:
            String(localized: "Clipboard Access", comment: "Permission name in Settings → Permissions")
        }
    }

    var explanation: String {
        switch self {
        case .accessibility:
            String(
                localized: "Lets Pounce paste into the app you were using. Without it, Pounce only copies.",
                comment: "Explanation of the Accessibility permission")
        case .fullDiskAccess:
            String(
                localized:
                    "Lets file search include Desktop, Documents, Downloads and iCloud Drive without asking about each folder.",
                comment: "Explanation of the Full Disk Access permission")
        case .pasteboard:
            String(
                localized:
                    "macOS can ask before an app reads the clipboard. Allow Pounce so the history keeps recording.",
                comment: "Explanation of the clipboard access permission")
        }
    }

    /// The state in words, so it never depends on the symbol's colour.
    func statusText(_ status: PermissionStatus) -> String {
        switch (self, status) {
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

extension PermissionStatus {
    var symbolName: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .denied: "hand.raised"
        case .notDetermined: "questionmark.circle"
        }
    }
}

/// Settings → Permissions: each permission the enabled features need, its state and a button to its page
/// in System Settings (spec: Pasek menu i Ustawienia → Uprawnienia).
struct PermissionsPane: View {
    let model: PermissionsModel

    var body: some View {
        Form {
            Section {
                let requirements = model.requirements
                if requirements.isEmpty {
                    Text(
                        "The features that are on need no system permissions.",
                        comment: "Settings → Permissions when no enabled feature needs a permission"
                    )
                    .foregroundStyle(.secondary)
                }
                ForEach(requirements) { requirement in
                    PermissionRow(
                        requirement: requirement,
                        status: model.status(of: requirement.permission),
                        open: { model.openSettings(for: requirement.permission) }
                    )
                }
            } header: {
                Text("Permissions", comment: "Settings section title")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(
                            "Pounce never asks for a permission on its own. Changes in System Settings apply right away.",
                            comment: "Settings → Permissions footer"
                        )
                        Spacer()
                        Button {
                            model.refresh()
                        } label: {
                            Text("Check Again", comment: "Button that re-reads the permission states")
                        }
                    }
                    Text(
                        "The Keychain needs no permission. A feature that keeps a key there shows its state in its own pane.",
                        comment: "Settings → Permissions note about the Keychain"
                    )
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refresh()
        }
    }
}

struct PermissionRow: View {
    let requirement: PermissionRequirement
    let status: PermissionStatus
    let open: () -> Void

    var body: some View {
        let permission = requirement.permission
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: permission.symbolName)
                .symbolRenderingMode(.hierarchical)
                .font(.title3)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(permission.title)
                    .accessibilityAddTraits(.isHeader)
                Label {
                    Text(permission.statusText(status))
                } icon: {
                    Image(systemName: status.symbolName)
                        .symbolRenderingMode(.hierarchical)
                        .accessibilityHidden(true)
                }
                .font(.callout.weight(.medium))
                Text(permission.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    "Needed by: \(requirement.pluginNames.formatted(.list(type: .and)))",
                    comment: "Settings → Permissions: the features that need a permission"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(action: open) {
                Text("Open System Settings…", comment: "Button that opens a permission's page in System Settings")
            }
            .accessibilityHint(
                Text(
                    "Opens \(permission.title) in System Settings",
                    comment: "Accessibility hint of the button that opens a permission's settings"))
        }
        .accessibilityElement(children: .contain)
    }
}
