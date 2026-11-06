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
    /// The recorded notes this plugin owns, read by the Notes section (`NoteSource`). Added with the Notes
    /// workspace; the default has none.
    var noteSources: [any NoteSource] { get }
    /// Notes only (step 4.6): how many copies of `owner`'s recordings the plugin keeps because the user edited or
    /// commented on them, so that Clear Library, Clear History, Erase Data and Delete in the owner can say so.
    /// Added with the Notes workspace; the default is 0.
    func keptNoteCopyCount(ofOwner owner: PluginID) async -> Int
    /// Notes only (step 4.6): deletes those copies, after the owner's own deletion succeeded and the user ticked
    /// "Also delete kept copies". `ownerErased` is true after Erase Data, when the owner can no longer be asked
    /// which recordings are gone. Returns `false` when something could not be deleted. The default deletes
    /// nothing and returns `true`.
    ///
    /// Both are owner-scoped: an implementation counts and deletes only copies of `owner`, and a second implementer
    /// must scope by owner the same way.
    func deleteKeptNoteCopies(ofOwner owner: PluginID, ownerErased: Bool) async -> Bool

    /// Removes data the plugin keeps outside its storage directory (for example a Keychain item).
    /// "Erase Data" calls `deactivate()`, then this method, and then the host deletes the whole
    /// `Plugins/<id>/` directory, so the default only needs to do nothing.
    func eraseData() async throws
}

extension LintelPlugin {
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
    public var noteSources: [any NoteSource] { [] }
    public func keptNoteCopyCount(ofOwner owner: PluginID) async -> Int { 0 }
    public func deleteKeptNoteCopies(ofOwner owner: PluginID, ownerErased: Bool) async -> Bool { true }
    public func eraseData() async throws {}
}
