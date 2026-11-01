import Foundation
import SwiftUI

/// Static description of a plugin.
public struct PluginManifest: Sendable {
    /// Stable identifier; it appears in item keys, paths and settings keys, so it never changes.
    public let id: PluginID
    public let displayName: LocalizedStringResource
    /// SF Symbol for the plugin's results section and settings pane.
    public let symbolName: String
    /// Order of result sections and settings panes; lower comes first.
    public let order: Int
    public let defaultEnabled: Bool

    public init(
        id: PluginID,
        displayName: LocalizedStringResource,
        symbolName: String,
        order: Int,
        defaultEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.symbolName = symbolName
        self.order = order
        self.defaultEnabled = defaultEnabled
    }
}

/// A feature of Pounce, compiled into the app and registered in `PluginRegistry`.
///
/// The host creates the plugin with its context, calls `activate()` when the plugin is enabled and
/// `deactivate()` when it is disabled or the app quits. Every contribution has an empty default, so a
/// small plugin implements only what it needs. Plugin code reports problems by throwing and never
/// traps (`fatalError`, `try!`, force unwrapping): all plugins share one process.
///
/// This protocol is a protected contract: changes are additive only and every new requirement gets a
/// default below (`BACKWARD_COMPATIBILITY.md` section 1).
@MainActor
public protocol PouncePlugin: AnyObject {
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
    func settingsPane() -> AnyView?
    /// Lines shown above the search results (progress, a missing permission). Added in Phase 3; the
    /// default shows nothing.
    var searchStatus: [SearchStatus] { get }

    /// Removes data the plugin keeps outside its storage directory (for example a Keychain item).
    /// "Erase Data" calls `deactivate()`, then this method, and then the host deletes the whole
    /// `Plugins/<id>/` directory, so the default only needs to do nothing.
    func eraseData() async throws
}

extension PouncePlugin {
    public func activate() async throws {}
    public func deactivate() async {}
    public var searchSources: [any SearchSource] { [] }
    public var commands: [PluginCommand] { [] }
    public var panelModes: [PanelMode] { [] }
    public var onboardingSteps: [OnboardingStep] { [] }
    public var requiredPermissions: Set<Permission> { [] }
    public func settingsPane() -> AnyView? { nil }
    public var searchStatus: [SearchStatus] { [] }
    public func eraseData() async throws {}
}
