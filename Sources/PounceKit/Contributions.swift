import Foundation
import SwiftUI

/// A command with an optional global shortcut and an optional menu bar item (for example
/// "Clipboard History" on Command-Shift-V).
public struct PluginCommand: Identifiable, Sendable {
    public let id: String
    public let title: LocalizedStringResource
    public let symbolName: String?
    public let defaultShortcut: KeyShortcut?
    /// Whether the command appears in the menu bar menu.
    public let showsInMenu: Bool
    public let run: @MainActor @Sendable () async -> Void

    public init(
        id: String,
        title: LocalizedStringResource,
        symbolName: String? = nil,
        defaultShortcut: KeyShortcut? = nil,
        showsInMenu: Bool = true,
        run: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.defaultShortcut = defaultShortcut
        self.showsInMenu = showsInMenu
        self.run = run
    }
}

/// A custom panel mode with its own view (for example the clipboard list with a preview).
public struct PanelMode: Identifiable, Sendable {
    public let id: PanelModeID
    public let title: LocalizedStringResource
    public let symbolName: String
    public let makeView: @MainActor @Sendable () -> AnyView

    public init(
        id: PanelModeID,
        title: LocalizedStringResource,
        symbolName: String,
        makeView: @escaping @MainActor @Sendable () -> AnyView
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.makeView = makeView
    }
}

/// One skippable first-launch step contributed by a plugin.
public struct OnboardingStep: Identifiable, Sendable {
    public let id: String
    public let title: LocalizedStringResource
    public let symbolName: String
    public let makeView: @MainActor @Sendable () -> AnyView

    public init(
        id: String,
        title: LocalizedStringResource,
        symbolName: String,
        makeView: @escaping @MainActor @Sendable () -> AnyView
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.makeView = makeView
    }
}

/// A system permission a plugin needs.
public enum Permission: String, Hashable, Sendable, CaseIterable {
    /// Accessibility, needed to post Command-V into the previous app.
    case accessibility
    /// Full Disk Access, needed to index protected folders without TCC prompts.
    case fullDiskAccess
    /// Reading the general pasteboard (pasteboard privacy, `NSPasteboard.accessBehavior`).
    case pasteboard
}

/// What the host knows about a permission.
public enum PermissionStatus: Hashable, Sendable {
    case granted
    case denied
    /// The system has not asked yet, or asks every time.
    case notDetermined
}
