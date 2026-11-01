import Foundation
import Observation
import PounceKit
import SwiftUI
import os

/// Shows and hides the panel window. Implemented by `PanelController`; tests use a fake, so the panel's
/// behaviour is tested without an `NSPanel`.
protocol PanelPresenting: AnyObject {
    func presentPanel()
    func dismissPanel()
}

/// State of the launcher panel: visibility, query, results, selection and the keyboard table.
///
/// Keyboard (spec: Klawiatura): ↑/↓ and ⌃P/⌃N move across sections; Return runs the first action and
/// Command-Return the second; a result action's own shortcut runs it; Esc and Command-W clear the query,
/// and close the panel when it is already empty; losing key focus closes it.
@Observable
final class PanelModel {
    enum Mode: Equatable {
        case search
        /// A plugin's own panel mode (Phase 2: clipboard).
        case plugin(PanelModeID)
    }

    /// Metrics from the spec, in points at the medium text size.
    enum Metrics {
        static let width: CGFloat = 760
        static let fieldHeight: CGFloat = 56
        static let maximumHeight: CGFloat = 480
        static let rowHeight: CGFloat = 40
        static let headerHeight: CGFloat = 26
        static let footerHeight: CGFloat = 32
        static let listPadding: CGFloat = 8
        static let messageHeight: CGFloat = 64
        /// One plugin status line (progress or notice) above the results.
        static let statusHeight: CGFloat = 36
    }

    private(set) var isVisible = false
    private(set) var mode: Mode = .search
    private(set) var query = ""
    private(set) var results = SearchResults.empty
    private(set) var isSearching = false
    /// Index into `results.items`.
    private(set) var selectedIndex: Int?
    var textSize = TextSize.default
    /// Set when a result action fails: the panel opens again with this message under the field, until
    /// the next keystroke or until it closes.
    private(set) var errorMessage: String?
    /// The selected filter of a list panel mode (Command-1…), or `nil` for all results.
    private(set) var modeFilter: PanelModeFilter.ID?

    @ObservationIgnored weak var presenter: (any PanelPresenting)?
    @ObservationIgnored var panelPresenter: (any PanelPresenter)?
    @ObservationIgnored var openSettings: () -> Void = {}
    /// Opens a plugin's own Settings pane (a status line's "Set Up…").
    @ObservationIgnored var openPluginSettings: (PluginID) -> Void = { _ in }
    @ObservationIgnored var announce: (String) -> Void = { message in
        AccessibilityNotification.Announcement(message).post()
    }
    @ObservationIgnored var previousApplication: () -> pid_t? = { nil }
    /// Finds an active plugin's panel mode.
    @ObservationIgnored var panelMode: (PanelModeID) -> PanelMode? = { _ in nil }
    /// Searches a list panel mode's own source (query, filter).
    @ObservationIgnored var modeSearch: (PanelMode, String, PanelModeFilter.ID?) async -> SearchResults? = { _, _, _ in
        nil
    }
    @ObservationIgnored private let search: (String) async -> SearchResults?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var announcementTask: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var previousApp: pid_t?
    @ObservationIgnored private let logger = Logger(subsystem: "app.pounce", category: "panel")

    /// The result count is announced after this long without typing.
    static let countAnnouncementDelay: Duration = .milliseconds(500)

    init(search: @escaping (String) async -> SearchResults?, clock: any Clock<Duration> = ContinuousClock()) {
        self.search = search
        self.clock = clock
    }

    // MARK: Visibility

    /// Opens the panel in a mode, remembering the frontmost app for actions that paste into it. Switching
    /// modes while the panel is open starts the new mode with an empty query.
    func show(mode: Mode = .search) {
        if !isVisible {
            previousApp = previousApplication()
        }
        let switched = mode != self.mode
        if switched {
            searchTask?.cancel()
            query = ""
            modeFilter = nil
            selectedIndex = nil
            results = .empty
        }
        self.mode = mode
        isVisible = true
        currentPanelMode?.willOpen?()
        presenter?.presentPanel()
        if switched || results.query.raw != query || results.sections.isEmpty {
            runSearch()
        }
    }

    /// The plugin panel mode shown now, if any.
    var currentPanelMode: PanelMode? {
        guard case .plugin(let id) = mode else { return nil }
        return panelMode(id)
    }

    /// The list panel mode shown now (the shell draws its list, preview and filters).
    var currentListMode: PanelMode? {
        currentPanelMode.flatMap { $0.isListMode ? $0 : nil }
    }

    /// Closes the panel and resets it, so the next opening starts with an empty query.
    func hide() {
        guard isVisible else { return }
        isVisible = false
        presenter?.dismissPanel()
        searchTask?.cancel()
        announcementTask?.cancel()
        query = ""
        errorMessage = nil
        selectedIndex = nil
        results = .empty
        mode = .search
        modeFilter = nil
    }

    /// The main shortcut while the panel is open closes it.
    func toggle() {
        isVisible ? hide() : show()
    }

    /// Esc and Command-W: clear the query first, close when it is already empty.
    func escape() {
        if query.isEmpty {
            hide()
        } else {
            updateQuery("")
        }
    }

    /// The panel lost key status (another window or app took focus).
    func resignedKey() {
        hide()
    }

    // MARK: Query

    func updateQuery(_ text: String) {
        guard text != query else { return }
        query = text
        errorMessage = nil
        runSearch()
    }

    /// A plugin's results changed while the panel may be open: search again so the list catches up
    /// (for example when the app index finishes loading after the panel opened).
    func resultsChanged() {
        guard isVisible else { return }
        let selectedID = selectedItem?.id
        runSearch(keeping: selectedID)
    }

    private func runSearch(keeping selectedID: String? = nil) {
        searchTask?.cancel()
        announcementTask?.cancel()
        let text = query
        let filter = modeFilter
        if case .plugin = mode, currentListMode == nil {
            // A view mode draws its own content; there is nothing to search.
            isSearching = false
            return
        }
        let listMode = currentListMode
        isSearching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            let found =
                if let listMode {
                    await modeSearch(listMode, text, filter)
                } else {
                    await search(text)
                }
            guard !Task.isCancelled, let found, text == query, filter == modeFilter else { return }
            apply(found, keeping: selectedID)
        }
    }

    /// Replaces the results and selects the row with `selectedID` if it is still there. When it is gone
    /// (for example it was just deleted), the row now at its position is selected, else the first.
    func apply(_ found: SearchResults, keeping selectedID: String? = nil) {
        let previousIndex = selectedIndex
        results = found
        isSearching = false
        let kept = selectedID.flatMap { id in found.items.firstIndex { $0.id == id } }
        let fallback = selectedID == nil ? 0 : min(previousIndex ?? 0, max(found.items.count - 1, 0))
        selectedIndex = found.items.isEmpty ? nil : (kept ?? fallback)
        scheduleCountAnnouncement()
    }

    /// Command-1…: selects the list mode's filter at `index`, or clears it when it is already selected.
    /// Returns whether the mode has such a filter.
    @discardableResult
    func toggleFilter(at index: Int) -> Bool {
        guard let filters = currentListMode?.filters, filters.indices.contains(index) else { return false }
        let id = filters[index].id
        modeFilter = modeFilter == id ? nil : id
        errorMessage = nil
        selectedIndex = nil
        runSearch()
        let title =
            modeFilter == nil
            ? String(localized: "All", comment: "Announced when a panel filter is cleared")
            : String(localized: filters[index].title)
        announce(title)
        return true
    }

    /// Waits for the current search (tests).
    func waitForSearch() async {
        await searchTask?.value
    }

    // MARK: Selection

    var selectedItem: ResultItem? {
        guard let selectedIndex, results.items.indices.contains(selectedIndex) else { return nil }
        return results.items[selectedIndex]
    }

    var selectedActions: [ResultAction] {
        guard let item = selectedItem else { return [] }
        return item.source.actions(for: item.candidate)
    }

    /// Moves the selection, crossing section boundaries and stopping at the ends. Announces the new row,
    /// because focus stays in the search field.
    func moveSelection(by delta: Int) {
        let count = results.items.count
        guard count > 0 else { return }
        let next = min(max((selectedIndex ?? -1) + delta, 0), count - 1)
        select(next)
    }

    func select(_ index: Int) {
        guard results.items.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        let item = results.items[index]
        announce("\(item.candidate.title), \(String(localized: item.kind))")
    }

    // MARK: Actions

    /// Return: the selected row's first action.
    func performPrimary() {
        perform(at: 0)
    }

    /// Command-Return: the selected row's second action.
    func performSecondary() {
        perform(at: 1)
    }

    /// Runs the selected row's action bound to `shortcut`. Returns whether one matched.
    @discardableResult
    func perform(shortcut: KeyShortcut) -> Bool {
        guard let action = selectedActions.first(where: { $0.shortcut == shortcut }) else { return false }
        perform(action)
        return true
    }

    private func perform(at index: Int) {
        let actions = selectedActions
        guard actions.indices.contains(index) else { return }
        perform(actions[index])
    }

    /// Hides the panel first (the action may open another app), then runs the action. If the action fails
    /// (for example the app was moved since the last scan), the panel opens again and says so. An action
    /// that keeps the panel open (deleting a clipboard entry) runs with the panel shown.
    func perform(_ action: ResultAction) {
        guard let panelPresenter else { return }
        let context = ActionContext(previousApp: previousApp, panel: panelPresenter, query: results.query)
        let itemTitle = selectedItem?.candidate.title
        if action.keepsPanelOpen {
            performInPlace(action, context: context, itemTitle: itemTitle)
            return
        }
        hide()
        let logger = logger
        actionTask = Task { [weak self] in
            do {
                try await action.perform(context)
            } catch {
                logger.error(
                    "Action \(action.id, privacy: .public) failed: \(String(describing: error), privacy: .private)"
                )
                guard !Self.isCancellation(error) else { return }
                self?.actionFailed(action, itemTitle: itemTitle)
            }
        }
    }

    private func performInPlace(_ action: ResultAction, context: ActionContext, itemTitle: String?) {
        let logger = logger
        actionTask = Task { [weak self] in
            do {
                try await action.perform(context)
            } catch {
                logger.error(
                    "Action \(action.id, privacy: .public) failed: \(String(describing: error), privacy: .private)"
                )
                guard !Self.isCancellation(error), let self, self.isVisible else { return }
                let message = Self.failureMessage(action, itemTitle: itemTitle)
                self.errorMessage = message
                self.announce(message)
            }
        }
    }

    /// Opens the panel with a message about the failed action and announces it.
    func actionFailed(_ action: ResultAction, itemTitle: String?) {
        let message = Self.failureMessage(action, itemTitle: itemTitle)
        show()
        errorMessage = message
        announce(message)
    }

    static func failureMessage(_ action: ResultAction, itemTitle: String?) -> String {
        let actionTitle = String(localized: action.title)
        return
            if let itemTitle
        {
            String(
                localized: "“\(actionTitle)” did not work for “\(itemTitle)”.",
                comment: "Panel message when a result action fails; action title, then the result's title"
            )
        } else {
            String(
                localized: "“\(actionTitle)” did not work.",
                comment: "Panel message when a result action fails; the action title"
            )
        }
    }

    /// The user cancelled (for example a system prompt about the app); that is not a failure to report.
    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    /// Waits for the last action (tests).
    func waitForAction() async {
        await actionTask?.value
    }

    // MARK: Layout and accessibility

    /// The panel's height: the field alone, or the field with the list and footer, up to 480 pt.
    var preferredHeight: CGFloat {
        let scale = textSize.scale
        // A plugin's panel mode always uses the full height (spec: the clipboard mode is 480 pt).
        if case .plugin = mode {
            return Metrics.maximumHeight
        }
        guard showsResultsArea else { return Metrics.fieldHeight }
        var content = Metrics.listPadding * 2
        content += CGFloat(results.statuses.count) * Metrics.statusHeight * scale
        if showsNoResults {
            content += Metrics.messageHeight
        }
        if errorMessage != nil {
            content += Metrics.messageHeight
        }
        for section in results.sections {
            content += Metrics.headerHeight * scale
            content += CGFloat(max(section.items.count, 1)) * Metrics.rowHeight * scale
        }
        let total = Metrics.fieldHeight + 1 + content + 1 + Metrics.footerHeight
        return min(total, Metrics.maximumHeight)
    }

    /// The list area shows when there are results or plugin status lines, when a typed query found
    /// nothing, or after a failed action.
    var showsResultsArea: Bool {
        errorMessage != nil || !results.sections.isEmpty || showsNoResults || !results.statuses.isEmpty
    }

    /// A status line's button: runs the plugin's closure, or opens the plugin's Settings pane.
    func perform(_ action: SearchStatusAction, of status: PanelStatus) {
        switch action.kind {
        case .run(let run):
            run()
        case .openSettings:
            hide()
            openPluginSettings(status.pluginID)
        }
    }

    var showsNoResults: Bool {
        results.sections.isEmpty && !query.isEmpty && !isSearching && results.query.raw == query
    }

    /// A list mode with nothing at all to show (no query, no filter): its own empty view replaces the
    /// list.
    var showsModeEmptyState: Bool {
        currentListMode != nil && results.items.isEmpty && query.isEmpty && modeFilter == nil && !isSearching
    }

    private func scheduleCountAnnouncement() {
        announcementTask?.cancel()
        guard !query.isEmpty else { return }
        let count = results.items.count
        let clock = clock
        announcementTask = Task { [weak self] in
            do {
                try await clock.sleep(for: Self.countAnnouncementDelay)
            } catch {
                return
            }
            self?.announce(
                count == 0
                    ? String(localized: "No Results", comment: "Panel state when nothing matches the query")
                    : String(localized: "Results: \(count)", comment: "Announced number of results")
            )
        }
    }
}
