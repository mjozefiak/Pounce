import Foundation
import SwiftUI

/// Static description of a plugin.
public struct PluginManifest: Sendable {
    /// Stable identifier; it appears in item keys, paths and settings keys, so it never changes.
    public let id: PluginID
    /// The feature's name in Settings (sidebar, pane title, Features) and wherever the shell names the feature.
    public let displayName: LocalizedStringResource
    /// SF Symbol for the plugin's results section and settings pane.
    public let symbolName: String
    /// Order of result sections and settings panes; lower comes first.
    public let order: Int
    public let defaultEnabled: Bool
    /// Whether the user may switch the plugin off. When `false` the host treats it as always enabled and
    /// ignores a stored `false`. Added with the main window; defaults to `true`.
    public let canBeDisabled: Bool
    /// The Settings sidebar group of the plugin's pane. Added with the main window; defaults to `.lintel`.
    public let settingsGroup: SettingsGroup
    /// One line that says what the feature does, under its name in Settings → Features ("Find files by name.").
    /// Added with the main window; defaults to `nil` (the row shows the name only).
    public let summary: LocalizedStringResource?
    /// The heading of the plugin's results in the launcher (its sections, the kind in Recently Used) when it should
    /// differ from `displayName` ("Applications" for Apps). Added with the main window; defaults to `nil`, which
    /// means `displayName`. Read it through `resultsTitle`.
    public let sectionTitle: LocalizedStringResource?

    public init(
        id: PluginID,
        displayName: LocalizedStringResource,
        symbolName: String,
        order: Int,
        defaultEnabled: Bool = true,
        canBeDisabled: Bool = true,
        settingsGroup: SettingsGroup = .lintel,
        summary: LocalizedStringResource? = nil,
        sectionTitle: LocalizedStringResource? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.symbolName = symbolName
        self.order = order
        self.defaultEnabled = defaultEnabled
        self.canBeDisabled = canBeDisabled
        self.settingsGroup = settingsGroup
        self.summary = summary
        self.sectionTitle = sectionTitle
    }

    /// The launcher's heading for the plugin's results: `sectionTitle`, else `displayName`.
    public var resultsTitle: LocalizedStringResource { sectionTitle ?? displayName }
}

/// A feature of Lintel, compiled into the app and registered in `PluginRegistry`.
///
/// The host creates the plugin with its context, calls `activate()` when the plugin is enabled and
/// `deactivate()` when it is disabled or the app quits. Every contribution has an empty default, so a
/// small plugin implements only what it needs. Plugin code reports problems by throwing and never
/// traps (`fatalError`, `try!`, force unwrapping): all plugins share one process.
///
/// This protocol is a protected contract: changes are additive only and every new requirement gets a
/// default below (`BACKWARD_COMPATIBILITY.md` section 1).
@MainActor
public protocol LintelPlugin: AnyObject {
    static var manifest: PluginManifest { get }

    init(context: PluginContext)

    /// Starts watchers, opens databases, runs migrations. Throwing moves only this plugin to `failed`.
    func activate() async throws

    /// Stops watchers and closes databases. Must be idempotent.
    func deactivate() async

    var searchSources: [any SearchSource] { get }
    /// Global shortcuts and menu bar items.
    var commands: [PluginCommand] { get }
    var panelModes: [PanelMode] { get }
    var onboardingSteps: [OnboardingStep] { get }
    var requiredPermissions: Set<Permission> { get }
    /// The plugin's Settings pane. It may be called while the plugin is inactive or `failed`, so it must not
    /// open stores, start work or download: it reads only settings and the read-only model install state.
    func settingsPane() -> AnyView?
    /// Lines shown above the search results (progress, a missing permission). Added in Phase 3; the
    /// default shows nothing.
    var searchStatus: [SearchStatus] { get }
    /// Suggestions for the empty search panel. Added with app suggestions; the default suggests nothing.
    var suggestionSources: [any SuggestionSource] { get }
    /// A control shown under `permission`'s row in Settings → Permissions, for example a "Test" button for a
    /// permission whose state cannot be read. Added with meeting notes; the default shows nothing.
    func permissionAccessory(for permission: Permission) -> AnyView?
    /// Sections of the main window's Workspace mode. Added with the main window; the default adds none.
    var workspaceSections: [WorkspaceSection] { get }
    /// The banner of the plugin's Settings pane, read only while the plugin is active. Added with the main
    /// window; the default `nil` lets the shell derive the banner from the host state and the permissions.
    var settingsStatus: SettingsStatus? { get }
    /// The downloadable models the plugin uses, for the Models pane. Added with the main window; the default
    /// uses none.
    var modelUsage: [ModelUsage] { get }

    /// Puts right what an earlier run left half done (window management: restores windows it parked), before
    /// the plugin is activated and whether or not it is enabled. The host runs it once per launch for every
    /// registered type, bounded to 5 seconds and in parallel with the other plugins, and again on app
    /// activation and on a permission change while it answers `.deferred`. It receives the plugin's context
    /// but no instance, and runs off the main actor. Added with window management; the default does nothing.
    nonisolated static func recoverAtLaunch(context: PluginContext) async -> RecoveryOutcome

    /// Offers a file the user opened with Lintel (double-clicked, or dropped on the Dock icon) to the plugin.
    /// Returns `true` when the plugin took it. The host asks the registered plugins in order until one does;
    /// an inactive plugin may be asked too, so it must only show a message then and start no work. Added with
    /// the layout library (`.lintellayouts`); the default takes nothing.
    func handleOpenedFile(_ url: URL) async -> Bool

    /// Removes data the plugin keeps outside its storage directory (for example a Keychain item).
    /// "Erase Data" calls `deactivate()`, then this method, and then the host deletes the whole
    /// `Plugins/<id>/` directory, so the default only needs to do nothing.
    func eraseData() async throws
}

extension LintelPlugin {
    public nonisolated static func recoverAtLaunch(context: PluginContext) async -> RecoveryOutcome { .done }
    public func handleOpenedFile(_ url: URL) async -> Bool { false }
    public func activate() async throws {}
    public func deactivate() async {}
    public var searchSources: [any SearchSource] { [] }
    public var commands: [PluginCommand] { [] }
    public var panelModes: [PanelMode] { [] }
    public var onboardingSteps: [OnboardingStep] { [] }
    public var requiredPermissions: Set<Permission> { [] }
    public func settingsPane() -> AnyView? { nil }
    public var searchStatus: [SearchStatus] { [] }
    public var suggestionSources: [any SuggestionSource] { [] }
    public func permissionAccessory(for permission: Permission) -> AnyView? { nil }
    public var workspaceSections: [WorkspaceSection] { [] }
    public var settingsStatus: SettingsStatus? { nil }
    public var modelUsage: [ModelUsage] { [] }
    public func eraseData() async throws {}
}
