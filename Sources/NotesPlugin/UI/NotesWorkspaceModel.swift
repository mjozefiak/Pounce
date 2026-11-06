import Foundation
import LintelKit
import Observation

/// The state of the Notes section (spec step 3.2): the explorer's rows and groups, the open tabs and one
/// `NoteDocumentModel` per open note. The model never writes anything; the text stays with the sources.
///
/// Everything is keyed by `NoteItemID`: a tab, an explorer row and a route name the same thing, so a note opened
/// from a route and from the explorer is one tab.
@MainActor @Observable
final class NotesWorkspaceModel {
    /// What the model needs from the outside, replaced by fakes in tests.
    struct Environment {
        var library: NoteLibrary
        /// The context's `noteSourcesChanged`: one stream per call.
        var sourceSetChanges: @Sendable () -> AsyncStream<Void> = { AsyncStream { $0.finish() } }
        var openSettings: @MainActor () -> Void = {}
        var now: @Sendable () -> Date = { Date() }
        var calendar: Calendar = .current
        var locale: Locale = .current
        var pageSize = 100
    }

    enum LoadState: Equatable {
        case loading
        case loaded
    }

    static let sectionID = "notes"

    private let environment: Environment
    let presentation: NoteRowPresentation

    private(set) var loadState: LoadState = .loading
    private(set) var rows: [NoteRow] = []
    private(set) var groups: [NoteGroup] = []
    private(set) var total = 0
    private(set) var unavailable: [UnavailableSource] = []
    private var cursor: NoteListCursor?
    var collapsed: Set<NoteGroupKey> = []

    var grouping: NoteGrouping = .time {
        didSet { if grouping != oldValue { regroup() } }
    }

    private(set) var tabs = NoteTabSet()
    private(set) var documents: [NoteItemID: NoteDocumentModel] = [:]

    init(environment: Environment) {
        self.environment = environment
        presentation = NoteRowPresentation(calendar: environment.calendar, locale: environment.locale)
    }

    // MARK: Listing

    var hasMore: Bool { cursor != nil }

    /// Lists the first page again (the first read, or a source said its notes changed) and refreshes the tabs'
    /// titles and the open documents.
    func refresh() async {
        let listing = await environment.library.list(matching: nil, after: nil, limit: environment.pageSize)
        rows = listing.rows
        cursor = listing.next
        total = listing.total
        unavailable = listing.unavailable
        loadState = .loaded
        regroup()
        syncTabs()
        await reloadOpenDocuments()
    }

    func loadMore() async {
        guard let cursor else { return }
        let listing = await environment.library.list(matching: nil, after: cursor, limit: environment.pageSize)
        guard listing.restarted == false else {
            await refresh()
            return
        }
        let known = Set(rows.map(\.id))
        rows += listing.rows.filter { !known.contains($0.id) }
        self.cursor = listing.next
        total = listing.total
        unavailable = listing.unavailable
        regroup()
        syncTabs()
    }

    /// The section's lifetime: reads the list, then again whenever a source (or the set of sources) changes.
    /// Returns when cancelled.
    func run() async {
        await refresh()
        for await _ in environment.library.changes(sourceSetChanges: environment.sourceSetChanges()) {
            if Task.isCancelled { return }
            await refresh()
        }
    }

    private func regroup() {
        groups = NoteGroupingRules.group(
            rows, by: grouping, now: environment.now(), calendar: environment.calendar)
    }

    func row(for id: NoteItemID) -> NoteRow? { rows.first { $0.id == id } }

    /// The explorer shows the date next to the time outside today and yesterday.
    func showsDate(_ row: NoteRow) -> Bool {
        switch NoteGroupingRules.timeKey(row.startedAt, now: environment.now(), calendar: environment.calendar) {
        case .today, .yesterday: false
        default: true
        }
    }

    func title(of row: NoteRow) -> String { presentation.title(row.summary) }

    func title(of group: NoteGroup) -> String {
        switch group.key {
        case .today: String(localized: "Today", comment: "Explorer: group of today's notes")
        case .yesterday: String(localized: "Yesterday", comment: "Explorer: group of yesterday's notes")
        case .previousSevenDays:
            String(localized: "Previous 7 Days", comment: "Explorer: group of the last week's notes")
        case .previousThirtyDays:
            String(localized: "Previous 30 Days", comment: "Explorer: group of the last month's notes")
        case .earlier: String(localized: "Earlier", comment: "Explorer: group of older notes")
        case .source(let id):
            switch id.rawValue {
            case "meetings": String(localized: "Meetings", comment: "Explorer: group of meeting notes")
            case "dictation": String(localized: "Dictation", comment: "Explorer: group of dictations")
            case "notes": String(localized: "Notes", comment: "Explorer: group of manual notes")
            default: id.rawValue
            }
        }
    }

    // MARK: Tabs

    var currentID: NoteItemID? { tabs.current }
    var currentDocument: NoteDocumentModel? { tabs.current.flatMap { documents[$0] } }

    /// Opens a note in its one tab, or selects that tab. The text is read by `loadContent`.
    func open(_ id: NoteItemID) {
        let row = row(for: id)
        let title = row.map(title(of:)) ?? id.key.rawValue
        tabs.open(
            NoteTab(id: id, kind: row?.summary.kind ?? .manual, title: title, isBusy: Self.isBusy(row?.badge)))
        if documents[id] == nil { documents[id] = NoteDocumentModel(id: id) }
    }

    func select(_ id: NoteItemID) {
        tabs.select(id)
    }

    func close(_ id: NoteItemID) {
        tabs.close(id)
        documents[id] = nil
    }

    /// ⌘W: closes the current tab. Returns `true` when other tabs stay, so the window stays; the last tab closes
    /// with the window (`WorkspaceSection.handleClose`).
    @discardableResult
    func closeCurrentTab() -> Bool {
        guard let id = tabs.current else { return false }
        let keepsWindow = tabs.tabs.count > 1
        close(id)
        return keepsWindow
    }

    /// `WorkspaceSection.handleRoute`: an `openNote` route opens the note and selects it. Any other route, or an
    /// id that is not a note key, is not handled.
    func handle(_ route: WorkspaceRoute) -> Bool {
        guard let id = NoteRoute.itemID(for: route) else { return false }
        open(id)
        return true
    }

    private func syncTabs() {
        for tab in tabs.tabs {
            guard let row = row(for: tab.id) else { continue }
            tabs.update(tab.id, title: title(of: row), isBusy: Self.isBusy(row.badge))
        }
    }

    private static func isBusy(_ badge: NoteBadge?) -> Bool {
        NoteRowPresentation.level(badge) == .active
    }

    // MARK: Documents

    /// Reads a note's content from its source. A source that is off or slow leaves the tab "unavailable"; only
    /// an answer of "no such note" makes it gone.
    func loadContent(_ id: NoteItemID) async {
        guard let document = documents[id] else { return }
        guard let source = await environment.library.source(for: id.key) else {
            document.markUnavailable()
            return
        }
        do {
            document.apply(try await source.content(for: id.key))
        } catch {
            document.markUnavailable()
        }
    }

    private func reloadOpenDocuments() async {
        for tab in tabs.tabs { await loadContent(tab.id) }
    }

    // MARK: Path bar and status bar

    /// Where the open note sits: its group, its title and, past the first layer, the layer shown.
    var pathComponents: [String]? {
        guard let id = tabs.current else { return nil }
        var parts: [String] = []
        let row = row(for: id)
        if let group = groups.first(where: { $0.rows.contains { $0.id == id } }) { parts.append(title(of: group)) }
        parts.append(row.map(title(of:)) ?? tabs.tabs.first { $0.id == id }?.title ?? id.key.rawValue)
        if let document = documents[id], document.layers.count > 1, let layerID = document.layerID,
            layerID != document.layers.first?.id
        {
            parts.append(NoteDocumentModel.title(ofLayer: layerID))
        }
        return parts
    }

    /// "27 notes · 1 writing".
    var statusSummary: String {
        let notes = String(localized: "\(total) notes", comment: "Notes status bar: how many notes the list holds")
        let writing = writingCount
        guard writing > 0 else { return notes }
        let active = String(
            localized: "\(writing) writing", comment: "Notes status bar: how many notes are being written")
        return "\(notes) · \(active)"
    }

    var writingCount: Int {
        rows.filter { if case .writing = $0.badge { true } else { false } }.count
    }

    // MARK: Chrome

    func openSettings() { environment.openSettings() }
}
