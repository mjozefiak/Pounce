import Foundation

/// A keyboard shortcut described without AppKit or SwiftUI types, so contracts stay portable and
/// `Sendable`.
public struct KeyShortcut: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    /// The key as the character it produces (`"c"`, `"v"`, `"\r"` for Return, `" "` for Space).
    public let key: String
    public let modifiers: Modifiers

    public init(key: String, modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// Presentation hooks an action may use. Implemented by the app shell.
public protocol PanelPresenter: Sendable {
    /// Hides the launcher panel.
    @MainActor func hidePanel()
    /// Shows a short, non-blocking confirmation (for example "Copied").
    @MainActor func showConfirmation(_ message: LocalizedStringResource)
}

/// What an action receives when it runs.
public struct ActionContext: Sendable {
    /// The app that was frontmost before the panel opened, if any.
    public let previousApp: pid_t?
    public let panel: any PanelPresenter
    /// The query the result was chosen for, so a source can record the query association through
    /// `UsageRecorder`. `nil` when the action does not come from a search. Added in Phase 1.
    public let query: NormalizedQuery?

    public init(previousApp: pid_t?, panel: any PanelPresenter, query: NormalizedQuery? = nil) {
        self.previousApp = previousApp
        self.panel = panel
        self.query = query
    }
}

/// An action on a search result. The panel footer and action shortcuts are generated from these, so
/// the shell never knows any plugin's actions.
public struct ResultAction: Identifiable, Sendable {
    public let id: String
    public let title: LocalizedStringResource
    public let symbolName: String
    public let shortcut: KeyShortcut?
    public let perform: @Sendable (ActionContext) async throws -> Void

    public init(
        id: String,
        title: LocalizedStringResource,
        symbolName: String,
        shortcut: KeyShortcut? = nil,
        perform: @escaping @Sendable (ActionContext) async throws -> Void
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.shortcut = shortcut
        self.perform = perform
    }
}
