import AppKit
import LintelKit
import LintelUI
import Observation
import SwiftUI

/// The state behind the one banner of the main window's Settings mode (spec step 2.2): which pane is shown, its
/// `StatusDerivation` banner, and the banner actions, which the shell runs.
///
/// The banner is read again when the pane appears (`show`), on every `PluginHost` state change, on
/// `PluginContext.resultsChanged` from the pane's plugin, on app activation and after a banner action finishes.
@Observable
final class SettingsHostModel {
    /// Where the banner actions lead; the shell owns navigation.
    struct Navigation {
        /// `.models(packageID:)`: the plugin id and the package id (the router's `openModels`).
        var openModels: (String, String?) -> Void = { _, _ in }
        /// `.systemSettings`: the permission's page.
        var openURL: (URL) -> Void = { _ in }
        /// After `.enablePlugin`: shortcuts and the menu follow the plugin.
        var pluginsChanged: () -> Void = {}
    }

    private(set) var paneID: String?
    private(set) var banner: StatusDerivation.Banner?
    /// True while a banner action runs.
    private(set) var isBusy = false

    @ObservationIgnored private let host: PluginHost
    @ObservationIgnored private let reader: any PermissionsReader
    @ObservationIgnored private let navigation: Navigation

    init(host: PluginHost, reader: any PermissionsReader, navigation: Navigation = Navigation()) {
        self.host = host
        self.reader = reader
        self.navigation = navigation
        observeHost()
    }

    /// The pane appeared or the selection changed.
    func show(_ paneID: String) {
        self.paneID = paneID
        refresh()
    }

    /// Reads the banner of the shown pane again.
    func refresh() {
        banner = paneID.flatMap { Self.banner(for: $0, host: host, reader: reader) }
    }

    /// `PluginContext.resultsChanged` from the plugin `pluginID`.
    func pluginResultsChanged(_ pluginID: String) {
        guard pluginID == paneID else { return }
        refresh()
    }

    /// Runs a banner button through the shell, then reads the banner again.
    func perform(_ action: SettingsStatusAction) async {
        guard let paneID, !isBusy else { return }
        isBusy = true
        defer {
            isBusy = false
            refresh()
        }
        switch action.destination {
        case .models(let packageID):
            navigation.openModels(paneID, packageID)
        case .systemSettings(let permission):
            navigation.openURL(permission.settingsURL)
        case .enablePlugin:
            // On a failed plugin this runs activation again (`activateNow` skips only `.active`).
            await host.setEnabled(true, for: PluginID(rawValue: paneID))
            navigation.pluginsChanged()
        case .plugin(_, let perform):
            await perform()
        }
    }

    /// The banner of a pane: a shell pane (no plugin) has none from derivation.
    static func banner(
        for paneID: String, host: PluginHost, reader: any PermissionsReader
    ) -> StatusDerivation.Banner? {
        guard let entry = host.entries.first(where: { $0.manifest.id.rawValue == paneID }) else { return nil }
        let state: StatusDerivation.HostState =
            switch entry.state {
            case .active: .active
            case .activating: .changing
            case .failed: .failed
            case .disabled: .off
            }
        let plugin = entry.plugin
        return StatusDerivation.banner(
            host: state,
            pluginStatus: { plugin.settingsStatus },
            required: Permission.allCases.filter(plugin.requiredPermissions.contains),
            permission: { reader.status(of: $0) })
    }

    /// Every lifecycle change of a plugin reads the banner again.
    private func observeHost() {
        withObservationTracking {
            _ = host.entries.map(\.state.isActive)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.observeHost()
            }
        }
    }
}

/// The main window's Settings mode: the sidebar, the one banner and the selected pane. Panes have no banner
/// slot; `SettingsWindowController` draws none.
struct SettingsHost: View {
    let model: SettingsHostModel
    let entries: [SettingsPaneAdapter.Entry]
    let sections: [SettingsSidebarModel.Section]
    let selection: String
    let onSelect: (String) -> Void
    let onBack: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(sections: sections, selection: selection, onSelect: onSelect, onBack: onBack)
            Divider()
            VStack(spacing: 0) {
                if let banner = model.banner, model.paneID == selection {
                    StatusBanner(banner: banner, isBusy: model.isBusy) { action in
                        Task { await model.perform(action) }
                    }
                    .padding([.horizontal, .top], 16)
                }
                ScrollView {
                    (entries.first { $0.id == selection } ?? entries.first)?.makeView()
                        .frame(maxWidth: .infinity)
                        .id(selection)
                }
            }
        }
        .task(id: selection) { model.show(selection) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}
