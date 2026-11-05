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
    /// Every plugin's pane, inactive ones included (`PluginHost.settingsPanes()`).
    private(set) var plugins: [SettingsPluginPane] = []
    /// The sidebar dot per plugin id: the level of that pane's banner when it is `attention` or `error`.
    private(set) var attention: [String: SettingsStatus.Level] = [:]
    /// True while a banner action runs.
    private(set) var isBusy = false

    @ObservationIgnored private let host: PluginHost
    @ObservationIgnored private let reader: any PermissionsReader
    @ObservationIgnored private let navigation: Navigation
    @ObservationIgnored private let makePanes: () -> [SettingsPluginPane]
    /// The derivation seam of the shell's own panes: a pane id here gets its banner from its closure (the Models
    /// pane's "1 model is needed"), read while the view draws so the pane's own observable state drives it.
    @ObservationIgnored private let shellBanners: [String: () -> StatusDerivation.Banner?]

    init(
        host: PluginHost, reader: any PermissionsReader, navigation: Navigation = Navigation(),
        panes: (() -> [SettingsPluginPane])? = nil,
        shellBanners: [String: () -> StatusDerivation.Banner?] = [:]
    ) {
        self.host = host
        self.reader = reader
        self.navigation = navigation
        self.shellBanners = shellBanners
        self.makePanes = panes ?? { host.settingsPanes() }
        reloadPanes()
        refreshAttention()
        observeHost()
    }

    /// The banner to draw above the shown pane: a shell pane's derived one through `shellBanners`, else the plugin
    /// pane's `banner`.
    var shownBanner: StatusDerivation.Banner? {
        guard let paneID else { return nil }
        if let derive = shellBanners[paneID] { return derive() }
        return banner
    }

    /// The sidebar sections from the current panes and dots.
    var sections: [SettingsSidebarModel.Section] {
        SettingsPanes.sidebarSections(plugins: plugins, attention: attention.merging(shellAttention) { $1 })
    }

    /// The dots of the shell's own panes (Permissions, Models, and General without a shortcut): the level of the
    /// banner `shellBanners` derives, read while the sidebar draws so the panes' observable state drives it.
    var shellAttention: [String: SettingsStatus.Level] {
        shellBanners.compactMapValues { StatusDerivation.attention($0()) }
    }

    /// The pane's title above its banner (the prototype's `h3`): the sidebar item's title.
    func title(of paneID: String) -> String? {
        SettingsPanes.sidebarSections(plugins: plugins).lazy.flatMap(\.items).first { $0.id == paneID }?.title
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

/// The main window's Settings mode: the sidebar, the pane title, the one banner and the selected pane. Panes have no banner
/// slot.
struct SettingsHost: View {
    let model: SettingsHostModel
    /// The shell's own panes (General, Features, Permissions, Advanced).
    let shellPane: (SettingsShellPane) -> AnyView
    /// Settings → Models (step 3.2).
    var modelsPane: (() -> AnyView)?
    let selection: String
    let onSelect: (String) -> Void
    let onBack: (() -> Void)?

    @Environment(\.lintelTextSize) private var textSize

    /// From the window's top edge to the pane title (prototype `.pane`, padding 20, plus the 1.45 line height).
    static let topInset: CGFloat = 22
    /// Between the pane title and the banner (prototype `.pane h3`, margin 12).
    static let titleSpacing: CGFloat = 12

    /// The pane of a disabled or failed plugin is dimmed under its banner (prototype `set-off`, `.dim`); the
    /// banner with its Turn On or Try Again stays at full strength.
    static func bodyOpacity(isActive: Bool) -> Double { isActive ? 1 : 0.5 }

    var body: some View {
        let entries = SettingsPanes.entries(
            shellPane: shellPane, plugins: model.plugins, models: modelsPane)
        let entry = entries.first { $0.id == selection } ?? entries.first
        HStack(spacing: 0) {
            SettingsSidebar(sections: model.sections, selection: selection, onSelect: onSelect, onBack: onBack)
            Divider()
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if let title = model.title(of: selection) {
                        Text(verbatim: title)
                            .font(textSize.paneTitleFont)
                            .accessibilityAddTraits(.isHeader)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, Self.titleSpacing)
                    }
                    if let banner = model.shownBanner, model.paneID == selection {
                        StatusBanner(banner: banner, isBusy: model.isBusy) { action in
                            Task { await model.perform(action) }
                        }
                    }
                }
                .settingsBannerColumn()
                .padding(.top, Self.topInset)
                ScrollView {
                    entry?.makeView()
                        .opacity(Self.bodyOpacity(isActive: entry?.isActive ?? true))
                        .settingsColumn()
                        .id(selection)
                }
            }
        }
        // The window's title bar is transparent over the content (`MainWindowController`): the sidebar runs to
        // the top under the traffic lights, as in the prototype.
        .ignoresSafeArea(.container, edges: .top)
        .task(id: selection) { model.show(selection) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}
