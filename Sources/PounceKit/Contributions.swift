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
    /// When set, the shell opens (or, when it is already open, closes) the panel in this plugin panel mode
    /// instead of calling `run`. Added in Phase 1, so a plugin can bind a global shortcut to its own mode.
    public let panelMode: PanelModeID?
    public let run: @MainActor @Sendable () async -> Void

    public init(
        id: String,
        title: LocalizedStringResource,
        symbolName: String? = nil,
        defaultShortcut: KeyShortcut? = nil,
        showsInMenu: Bool = true,
        panelMode: PanelModeID? = nil,
        run: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.defaultShortcut = defaultShortcut
        self.showsInMenu = showsInMenu
        self.panelMode = panelMode
        self.run = run
    }
}

/// A filter of a list panel mode, chosen with Command-1 to Command-9 in the order given (for example the
/// clipboard's type filter). Added in Phase 2.
public struct PanelModeFilter: Identifiable, Sendable {
    public let id: String
    public let title: LocalizedStringResource
    public let symbolName: String

    public init(id: String, title: LocalizedStringResource, symbolName: String) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
    }
}

/// The results of a list panel mode. Unlike a `SearchSource`, a mode source answers alone, receives the
/// mode's filter, and its order is kept as is: the shell does not rank it and never reads or writes
/// `ranking.sqlite` for it. Added in Phase 2.
public protocol PanelModeSource: Sendable {
    /// Runs off the main actor and reacts to `Task` cancellation, like `SearchSource.search`.
    func search(_ query: NormalizedQuery, filter: PanelModeFilter.ID?, limit: Int) async throws -> [Candidate]

    /// Actions for a candidate: the first one runs on Return, the second on Command-Return, any other by
    /// its shortcut.
    func actions(for candidate: Candidate) -> [ResultAction]
}

extension PanelModeSource {
    public func actions(for candidate: Candidate) -> [ResultAction] { [] }
}

/// A custom panel mode with its own view (for example the clipboard list with a preview).
///
/// Two kinds exist. A **view mode** (`source == nil`) shows `makeView()` below the search field and
/// handles everything itself. A **list mode** (Phase 2) gives a `source`: the shell then draws the
/// search field, a result list driven by the keyboard table, the selected candidate's preview beside
/// it, the filters and the action footer, and `makeView()` becomes the status area above the list
/// (banners; an `EmptyView` when there is nothing to say).
public struct PanelMode: Identifiable, Sendable {
    public let id: PanelModeID
    public let title: LocalizedStringResource
    public let symbolName: String
    public let makeView: @MainActor @Sendable () -> AnyView
    /// The list mode's results. `nil` for a view mode. Added in Phase 2.
    public let source: (any PanelModeSource)?
    /// The list mode's filters, chosen with Command-1… in this order. Added in Phase 2.
    public let filters: [PanelModeFilter]
    /// The preview of the selected candidate, beside the list. Added in Phase 2.
    public let makePreview: (@MainActor @Sendable (Candidate) -> AnyView)?
    /// Shown instead of the list when an empty query (with no filter) finds nothing. Added in Phase 2.
    public let makeEmptyView: (@MainActor @Sendable () -> AnyView)?
    /// Called each time the panel opens in this mode, before the first search. Added in Phase 2.
    public let willOpen: (@MainActor @Sendable () -> Void)?

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
        self.source = nil
        self.filters = []
        self.makePreview = nil
        self.makeEmptyView = nil
        self.willOpen = nil
    }

    /// A list mode (added in Phase 2).
    public init(
        id: PanelModeID,
        title: LocalizedStringResource,
        symbolName: String,
        source: any PanelModeSource,
        filters: [PanelModeFilter] = [],
        makeStatus: @escaping @MainActor @Sendable () -> AnyView = { AnyView(EmptyView()) },
        makePreview: (@MainActor @Sendable (Candidate) -> AnyView)? = nil,
        makeEmptyView: (@MainActor @Sendable () -> AnyView)? = nil,
        willOpen: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.makeView = makeStatus
        self.source = source
        self.filters = filters
        self.makePreview = makePreview
        self.makeEmptyView = makeEmptyView
        self.willOpen = willOpen
    }

    /// Whether the shell draws the list (`source` is set).
    public var isListMode: Bool { source != nil }
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
