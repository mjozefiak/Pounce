import AppKit
import LintelKit
import LintelUI
import Observation
import SwiftUI

/// The state behind the main window's Settings mode (spec step 2.2): which pane is shown, its `StatusDerivation`
/// banner, the banner actions (which the shell runs), and the plugin panes with their sidebar dots.
///
/// The banner and the dots are read again when the pane appears (`show`), on every `PluginHost` state change, on
/// `PluginContext.resultsChanged` (the banner only from the pane's plugin), on app activation and after a banner
/// action finishes. The plugin panes (`plugins`: dimmed rows, `isActive`) are built again on every `PluginHost`
/// state change and after `.enablePlugin`, so the sidebar and the pane follow "Turn On", "Try Again" and the
/// Features switches.
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
    /// Every plugin's pane, inactive ones included (`PluginHost.settingsPanes(includingInactive: true)`).
    private(set) var plugins: [SettingsWindowController.PluginPane] = []
    /// The sidebar dot per plugin id: the level of that pane's banner when it is `attention` or `error`.
    private(set) var attention: [String: SettingsStatus.Level] = [:]
    /// True while a banner action runs.
    private(set) var isBusy = false

    @ObservationIgnored private let host: PluginHost
    @ObservationIgnored private let reader: any PermissionsReader
    @ObservationIgnored private let navigation: Navigation
    @ObservationIgnored private let makePanes: () -> [SettingsWindowController.PluginPane]

    init(
        host: PluginHost, reader: any PermissionsReader, navigation: Navigation = Navigation(),
        panes: (() -> [SettingsWindowController.PluginPane])? = nil
    ) {
        self.host = host
        self.reader = reader
        self.navigation = navigation
        self.makePanes = panes ?? { host.settingsPanes(includingInactive: true) }
        reloadPanes()
        refreshAttention()
        observeHost()
    }

    /// The sidebar sections from the current panes and dots.
    var sections: [SettingsSidebarModel.Section] {
        SettingsPaneAdapter.sidebarSections(plugins: plugins, attention: attention)
    }

    /// Builds the plugin panes again (a plugin's `settingsPane()` reflects whether it is active).
    func reloadPanes() {
        plugins = makePanes()
    }

    /// The pane appeared or the selection changed.
    func show(_ paneID: String) {
        self.paneID = paneID
        refresh()
    }

    /// Reads the banner of the shown pane again.
    func refresh() {
        banner = paneID.flatMap { Self.banner(for: $0, host: host, reader: reader) }
        refreshAttention()
    }

    /// `PluginContext.resultsChanged` from the plugin `pluginID`: its dot, and the banner when it is shown.
    func pluginResultsChanged(_ pluginID: String) {
        guard pluginID == paneID else {
            refreshAttention()
            return
        }
        refresh()
    }

    private func refreshAttention() {
        var levels: [String: SettingsStatus.Level] = [:]
        for entry in host.entries {
            let id = entry.manifest.id.rawValue
            levels[id] = StatusDerivation.attention(Self.banner(for: id, host: host, reader: reader))
        }
        if levels != attention { attention = levels }
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
            reloadPanes()
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

    /// Every lifecycle change of a plugin builds the panes and reads the banner and the dots again.
    private func observeHost() {
        withObservationTracking {
            _ = host.entries.map(\.state.isActive)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reloadPanes()
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
    /// The shell's own panes (General, Features, Permissions, Advanced).
    let shellPane: (SettingsWindowController.Pane) -> AnyView
    let selection: String
    let onSelect: (String) -> Void
    let onBack: (() -> Void)?

    var body: some View {
        let entries = SettingsPaneAdapter.entries(shellPane: shellPane, plugins: model.plugins)
        HStack(spacing: 0) {
            SettingsSidebar(sections: model.sections, selection: selection, onSelect: onSelect, onBack: onBack)
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
