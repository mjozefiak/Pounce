import Foundation
import LintelKit
import SwiftUI

/// Window management: workspaces, tiling and zone layouts (spec `2026-11-09-window-management`). Built in
/// steps; this is the skeleton of step 1.3 (manifest, settings, availability check). It is **not registered in
/// `PluginRegistry`** until the last step of Phase 1 (1.12), so no empty "Window Management" toggle reaches
/// users before the feature works.
///
/// Nothing moves unless the plugin is enabled and Accessibility is trusted. The failure mode of every problem is
/// a disabled feature with a banner, never a crash or a window left parked: plugin code never traps, window
/// titles and bundle ids never reach a log, `ranking.sqlite` or `state.json`. Settings: `plugins.windows.*`
/// (`WindowsSettings.Key`). Disabled by default.
@MainActor
public final class WindowsPlugin: LintelPlugin {
    public nonisolated static let manifest = PluginManifest(
        id: "windows",
        displayName: LocalizedStringResource("Window Management", comment: "Plugin name of window management"),
        symbolName: "rectangle.3.group",
        order: 60,
        defaultEnabled: false,
        settingsGroup: .lintel,
        summary: LocalizedStringResource(
            "Arrange windows in workspaces.", comment: "Settings → Features: what Window Management does")
    )

    /// Why `activate()` refused to start.
    public enum StartError: Error, Equatable {
        /// The window client cannot work on this Mac (for example the window-id symbol is missing).
        case unsupported(reason: String)
    }

    let context: PluginContext
    let settings: WindowsSettings

    public init(context: PluginContext) {
        self.context = context
        self.settings = WindowsSettings(context.settings)
    }

    public var requiredPermissions: Set<Permission> { [.accessibility] }

    /// Throws when the window client is `unsupported`, so the host marks the plugin `failed` (spec: API
    /// Contracts). Everything else the engine needs is started by later steps.
    public func activate() async throws {
        if case .unsupported(let reason) = context.windows.availability {
            throw StartError.unsupported(reason: reason)
        }
    }

    public func deactivate() async {}
}
