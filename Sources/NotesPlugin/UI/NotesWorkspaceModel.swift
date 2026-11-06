import Foundation
import LintelCore
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
        /// Where Copy Markdown writes (the context's pasteboard).
        var pasteboard: any PasteboardClient
        /// Where Save .md asks for a place and writes.
        var saver: any NoteFileSaving = NoteSavePanel()
        /// The context's `noteSourcesChanged`: one stream per call.
        var sourceSetChanges: @Sendable () -> AsyncStream<Void> = { AsyncStream { $0.finish() } }
        var openSettings: @MainActor () -> Void = {}
        /// "Open Models" of the needs-model strip (`PluginContext.openModels`).
        var openModels: @MainActor () -> Void = {}
        /// The plugins whose recordings Notes lists; with none of them active the section says recording is off.
        var recordingPluginIDs: Set<PluginID> = ["meetings", "dictation"]
        var now: @Sendable () -> Date = { Date() }
        var calendar: Calendar = .current
        var locale: Locale = .current
        var pageSize = 100
        /// `plugins.notes.*`, for the inspector's Details toggles; `nil` keeps them in memory (tests).
        var settings: PluginSettings?
        /// The Details toggles shared with Settings → Notes; `nil` makes them from `settings`.
        var preferences: NoteViewPreferences?
        /// The clock and budget of a source's `content(for:)`, like the listing's: a source that does not answer in
        /// time leaves the tab "unavailable" and does not hold up the other tabs.
        var clock: any Clock<Duration> = ContinuousClock()
        var contentBudget: Duration = SourceFanOut.defaultBudget
        /// The open documents (one writer each). `nil` until the store is wired (tests, QA without a store).
        var registry: NoteDocumentRegistry?
        /// The overlaid layers of a note, read from `notes.sqlite` when it is opened; empty when there are none or
        /// the store cannot be read.
        var overlayHeads: @Sendable (NoteItemID) async -> [OverlayLayerHead] = { _ in [] }
        /// Reconciles a note's overlays with its source when it is opened.
        var reconcile: @Sendable (NoteKey) async -> Void = { _ in }
        /// The detach sweep loop: runs on source activation and every 10 minutes while the section is alive.
        var sweepLoop: @Sendable () async -> Void = {}
        /// New notes and editing need the store (and `plugins.notes.readOnly` off); without it ⌘N and the pen are off.
        var canCreateNotes = false
        var canEditNotes = false
        /// Creates a manual note (`notes:<uuid>`) and returns its key; `nil` when it could not be written.
        var createManualNote: @Sendable () async -> NoteKey? = { nil }
        /// Writes a manual note's `title_override` (`nil` clears it); `false` when it could not be written.
        var setTitle: @Sendable (NoteKey, String?) async -> Bool = { _, _ in false }
        /// The editor's session for a layer of a loaded note (its writer and the rules of seeding); `nil` when the
        /// layer cannot be edited now.
        var makeEditingSession: @MainActor (NoteContent, String, NoteDocumentModel) -> NoteEditingSession? = {
            _, _, _ in nil
        }
        /// The history of a layer (its revisions) from `notes.sqlite`; `.none` when the layer has no overlay.
        var loadHistory: @MainActor (NoteItemID, String) async -> HistoryState = { _, _ in .none }
        /// Restore: a new `human` revision with the text and authors of the revision, through the layer's one
        /// writer. `false` when nothing was written (read-only, store locked, the revision is gone).
        var restoreRevision: @MainActor (NoteItemID, String, Int64) async -> Bool = { _, _, _ in false }
        /// Delete: the owner first, the overlays only after it succeeded (`NoteDeleter`); throws a
        /// `NoteDeleter.Failure`. Off (`canDeleteNotes` false) without the store.
        var canDeleteNotes = false
        var deleteNote: @MainActor (NoteItemID) async throws -> Void = { _ in
            throw NoteDeleter.Failure.sourceUnavailable
        }
        /// Renames the title of a recorded note in its owner (`NoteSourceEditing`); `false` when it was not changed.
        var renameTitle: @MainActor (NoteKey, String) async -> Bool = { _, _ in false }
    }

    enum LoadState: Equatable {
        case loading
        case loaded
    }

    static let sectionID = "notes"

    let environment: Environment
    let presentation: NoteRowPresentation
    /// The Details toggles (author bars, source quotes, wrapped lines).
    let preferences: NoteViewPreferences
    /// The inspector on the right (Details and History; Comments join it in step 5.2).
    var inspectorVisible = true
    var inspectorTab: NoteInspectorTab = .details
    /// The question the delete sheet shows, `nil` when none is open.
    var pendingDelete: DeleteRequest?

    private(set) var loadState: LoadState = .loading
    private(set) var rows: [NoteRow] = []
    private(set) var groups: [NoteGroup] = []
    private(set) var total = 0
    private(set) var unavailable: [UnavailableSource] = []
    /// `false` when `notes.sqlite` could not be read: the sources stay listed, writing is off (spec "Edge Cases").
    private(set) var overlaysAvailable = true
    private(set) var activePlugins: Set<PluginID> = []
    private var cursor: NoteListCursor?
    /// Counts every `refresh()`: an answer that arrives after a newer refresh began is dropped.
    private var listEpoch = 0
    private var isLoadingMore = false
    /// Changes whenever the rows or the cursor change; the explorer's "load more" sentinel is keyed on it, so it
    /// asks again while it is still on screen after a page came in.
    private(set) var pageToken = 0
    /// Counts the reads of each open note's content: only the newest read of a note may apply its answer.
    private var contentEpochs: [NoteItemID: Int] = [:]
    private var isSaving = false

    /// What the explorer's search field holds; `runSearch()` lists with it.
    var searchText = ""
    /// The query the rows on screen answer, `nil` while browsing.
    private(set) var searchQuery: NormalizedQuery?
    var collapsed: Set<NoteGroupKey> = []

    var grouping: NoteGrouping = .time {
        didSet { if grouping != oldValue { regroup() } }
    }

    #if DEBUG
    /// QA (`plugins.notes.qaOpen`): the layer a note shows once its content has been read.
    var preferredLayers: [NoteItemID: String] = [:]
    /// QA (`plugins.notes.qaState=loading`): `run()` never reads, so the loading screen stays.
    var holdsLoading = false
    /// QA (`plugins.notes.qaSearch`): the text typed into the search field once the first list is in.
    var initialSearch: String?
    /// `plugins.notes.qaEditor`: `on` or `readonly` shows the open note in the editor.
    var qaEditor: String?
    /// `plugins.notes.qaAttribution=mixed`.
    var qaMixedAuthors = false
    #endif

    private(set) var tabs = NoteTabSet()
    private(set) var documents: [NoteItemID: NoteDocumentModel] = [:]

    init(environment: Environment) {
        self.environment = environment
        presentation = NoteRowPresentation(calendar: environment.calendar, locale: environment.locale)
        preferences = environment.preferences ?? NoteViewPreferences(settings: environment.settings)
    }

    // MARK: Listing

    var hasMore: Bool { cursor != nil }

    /// Lists the first page again (the first read, or a source said its notes changed) and refreshes the tabs'
    /// titles and the open documents. While a search is on, it is the search's first page.
    func refresh() async {
        listEpoch += 1
        let epoch = listEpoch
        let query = searchQuery
        let listing = await environment.library.list(matching: query, after: nil, limit: environment.pageSize)
        let plugins = Set(await environment.library.activePluginIDs)
        guard epoch == listEpoch, query == searchQuery else { return }
        rows = listing.rows
        cursor = listing.next
        total = listing.total
        unavailable = listing.unavailable
        overlaysAvailable = listing.overlaysAvailable
        activePlugins = plugins
        loadState = .loaded
        pageToken += 1
        regroup()
        syncTabs()
        await reloadOpenDocuments()
    }

    func loadMore() async {
        guard let cursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let epoch = listEpoch
        let query = searchQuery
        let listing = await environment.library.list(matching: query, after: cursor, limit: environment.pageSize)
        // A refresh (or another query) began meanwhile: its rows and cursor are newer than this page.
        guard epoch == listEpoch, query == searchQuery else { return }
        guard listing.restarted == false else {
            await refresh()
            return
        }
        let known = Set(rows.map(\.id))
        rows += listing.rows.filter { !known.contains($0.id) }
        self.cursor = listing.next
        total = listing.total
        unavailable = listing.unavailable
        pageToken += 1
        regroup()
        syncTabs()
    }

    // MARK: Search

    /// Lists with the text in the search field: every source's `list(matching:)` merged newest first, paged like
    /// the browse list. An empty (or blank) field goes back to the browse list. Notes' own manual notes and the
    /// full-text hits of `notes.sqlite` join a query with the store (step 4.0).
    func runSearch() async {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = trimmed.isEmpty ? nil : TextNormalizer.query(trimmed)
        let next = (query?.isEmpty == false) ? query : nil
        if next == searchQuery { return }
        searchQuery = next
        await refresh()
    }

    /// The field's clear button and Escape.
    func clearSearch() async {
        searchText = ""
        await runSearch()
    }

    var isSearching: Bool { searchQuery != nil }

    /// While a search is on: the first matched layer's snippet (plain text; the view marks the query's words).
    func snippetText(of row: NoteRow) -> String? {
        guard searchQuery != nil else { return nil }
        let text = row.summary.matches.first?.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    /// The section's lifetime: reads the list, then again whenever a source (or the set of sources) changes.
    /// Returns when cancelled.
    func run() async {
        #if DEBUG
        if holdsLoading { return }
        #endif
        let sweeps = Task { await environment.sweepLoop() }
        defer { sweeps.cancel() }
        await refresh()
        #if DEBUG
        if let text = initialSearch {
            initialSearch = nil
            searchText = text
            await runSearch()
        }
        #endif
        for await _ in environment.library.changes(sourceSetChanges: environment.sourceSetChanges()) {
            if Task.isCancelled { return }
            await refresh()
        }
    }

    private func regroup() {
        // A search answer is one flat list, best newest first, so the groups would only get in the way.
        guard searchQuery == nil else {
            groups = []
            return
        }
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
        if documents[id] == nil { documents[id] = makeDocument(id) }
    }

    /// A document model whose editor, when it ends, writes what is typed and reads the note again.
    private func makeDocument(_ id: NoteItemID) -> NoteDocumentModel {
        let document = NoteDocumentModel(id: id)
        document.onEditingEnded = { [weak self] session in
            Task { @MainActor in await self?.finishEditing(id, session) }
        }
        return document
    }

    func select(_ id: NoteItemID) {
        tabs.select(id)
    }

    func close(_ id: NoteItemID) {
        tabs.close(id)
        documents[id] = nil
        contentEpochs[id] = nil
        // The buffer is written before the document is forgotten, then the deferred delete of a detached row runs.
        if let registry = environment.registry { Task { await registry.release(item: id) } }
    }

    /// A detach re-keyed an open note: its tab and document move from `.live(key)` to
    /// `.detached(key, startedAtMs:)` and are labelled "Recording removed". A new live note with the same key
    /// (a recreated store's row 1) is a different identity and opens in its own tab.
    @discardableResult
    func rekeyDetached(key: NoteKey, startedAtMs: Int64) -> Bool {
        let old = NoteItemID.live(key)
        let new = NoteItemID.detached(key, startedAtMs: startedAtMs)
        guard tabs.rekey(from: old, to: new) else { return false }
        documents[new] = documents.removeValue(forKey: old).map { _ in makeDocument(new) }
        contentEpochs[old] = nil
        let title = tabs.tabs.first { $0.id == new }?.title ?? key.rawValue
        tabs.update(new, title: title, isBusy: false)
        Task { await loadContent(new) }
        return true
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
        let epoch = (contentEpochs[id] ?? 0) + 1
        contentEpochs[id] = epoch
        if case .detached = id {
            // A detached note shows only its overlaid layers; the source is never asked (it would answer with
            // the text of another recording, or of none).
            let heads = await environment.overlayHeads(id)
            guard isCurrent(epoch, id, document) else { return }
            if let content = NoteOverlayContent.compose(
                item: id, source: nil, heads: heads, summary: row(for: id)?.summary)
            {
                document.apply(content, attributions: NoteOverlayContent.attributions(heads: heads))
                document.setActions([])
                await refreshHistoryIfShown(id)
            } else {
                document.markUnavailable()
            }
            return
        }
        if document.isManual {
            // A manual note has no source: its text is the head of its own document.
            let heads = await environment.overlayHeads(id)
            guard isCurrent(epoch, id, document) else { return }
            if let content = NoteOverlayContent.compose(
                item: id, source: nil, heads: heads, summary: row(for: id)?.summary)
            {
                document.apply(content, attributions: NoteOverlayContent.attributions(heads: heads))
                document.setActions([])
                if document.wantsEditing { beginEditing(id) }
                await refreshHistoryIfShown(id)
            } else {
                document.markUnavailable()
            }
            return
        }
        guard let source = await environment.library.source(for: id.key) else {
            if isCurrent(epoch, id, document) { document.markUnavailable() }
            return
        }
        let key = id.key
        await environment.reconcile(key)
        guard isCurrent(epoch, id, document) else { return }
        let outcome = await SourceFanOut.call(budget: environment.contentBudget, clock: environment.clock) {
            try await source.content(for: key)
        }
        // The tab was closed, or a newer read of this note began: its answer wins.
        guard isCurrent(epoch, id, document) else { return }
        switch outcome {
        case .value(let read):
            let heads = await environment.overlayHeads(id)
            guard isCurrent(epoch, id, document) else { return }
            document.apply(
                NoteOverlayContent.compose(item: id, source: read, heads: heads, summary: nil),
                attributions: NoteOverlayContent.attributions(heads: heads))
            document.setActions(source.actions(for: key))
            document.canRenameTitle = source is any NoteSourceEditing
            await refreshHistoryIfShown(id)
            #if DEBUG
            if qaMixedAuthors { document.qaMixAuthors() }
            if let layer = preferredLayers.removeValue(forKey: id) { document.selectLayer(layer) }
            #endif
        case .failed, .timedOut:
            document.markUnavailable()
        case .cancelled:
            break
        }
    }

    /// The note is gone (deleted): its tab and document go without writing anything again (the registry already
    /// discarded the writers).
    func dropTab(_ id: NoteItemID) {
        tabs.close(id)
        documents[id] = nil
        contentEpochs[id] = nil
    }

    private func isCurrent(_ epoch: Int, _ id: NoteItemID, _ document: NoteDocumentModel) -> Bool {
        contentEpochs[id] == epoch && documents[id] === document
    }

    /// Every open tab is read on its own, so a source that does not answer holds up only its own tabs.
    private func reloadOpenDocuments() async {
        let reads = tabs.tabs.map { tab in Task { await loadContent(tab.id) } }
        for read in reads { await read.value }
    }

    // MARK: New notes (step 4.4)

    /// ⌘N and the explorer's "+": possible with the store open for writing.
    var canCreateNote: Bool { environment.canCreateNotes && overlaysAvailable && !isCreatingNote }

    private var isCreatingNote = false

    /// Creates a manual note, lists it, and opens it in its tab with the editor ready. A search in the explorer
    /// is cleared first, so the new row is visible.
    func newNote() async {
        guard canCreateNote else { return }
        isCreatingNote = true
        defer { isCreatingNote = false }
        guard let key = await environment.createManualNote() else {
            show(.createFailed)
            return
        }
        if isSearching { await clearSearch() } else { await refresh() }
        let id = NoteItemID.live(key)
        open(id)
        documents[id]?.wantsEditing = true
        await loadContent(id)
    }

    /// Whether the title of a recorded note is a field: its owner supports renaming and the note is still there.
    func canRenameTitle(_ document: NoteDocumentModel) -> Bool {
        if case .detached = document.id { return false }
        return document.canRenameTitle && !document.isManual
    }

    /// Whether the title field accepts typing: a manual note needs the store; a recorded one only its owner.
    func canEditTitle(_ document: NoteDocumentModel) -> Bool {
        document.isManual ? environment.canEditNotes : canRenameTitle(document)
    }

    /// A manual note's title: the line above its text. Trimmed and cleaned like `NotesStore.cleanTitle`; an empty
    /// one clears it. Nothing happens when it did not change.
    func setTitle(_ id: NoteItemID, to text: String) async {
        guard let document = documents[id], document.isManual || canRenameTitle(document) else { return }
        let clean = NotesStore.cleanTitle(text)
        let current = NotesStore.cleanTitle(row(for: id)?.summary.title ?? document.summary?.title)
        guard clean != current else { return }
        // A manual note's title is Notes' own (`title_override`); a recorded note's belongs to its owner and is
        // renamed through `NoteSourceEditing`, never in `notes.sqlite`.
        let written =
            document.isManual
            ? await environment.setTitle(id.key, clean) : await environment.renameTitle(id.key, clean ?? "")
        guard written else {
            show(.titleFailed)
            return
        }
        await refresh()
    }

    // MARK: Editing (step 4.4)

    /// The most that opens in the editor; a longer layer (a 3-hour transcript) stays read-only with Export.
    static let editableLimit = 200_000

    /// Whether the pen is on for the open layer (spec: seeding only in the states it allows, an overlay or a manual
    /// note always, never with `plugins.notes.readOnly`, never beyond the size limit or on a detached note).
    func canEdit(_ document: NoteDocumentModel) -> Bool {
        guard environment.canEditNotes, document.phase == .loaded, let content = document.content,
            let layer = document.selectedLayer
        else { return false }
        if case .detached = document.id { return false }
        if layer.markdown.utf16.count > Self.editableLimit { return false }
        if document.isManual || document.attributions[layer.id] != nil { return true }
        return OverlaySeeder.canSeed(state: content.summary.state, layer: layer)
    }

    /// The pen of the path bar: the editor for the shown layer, or back to reading.
    func toggleEditing() {
        guard let id = currentID, let document = documents[id] else { return }
        if document.isEditing {
            document.leaveEditing()
        } else {
            beginEditing(id)
        }
    }

    func beginEditing(_ id: NoteItemID) {
        guard let document = documents[id], !document.isEditing, canEdit(document), let content = document.content,
            let layerID = document.layerID,
            let session = environment.makeEditingSession(content, layerID, document), session.isEditable
        else { return }
        document.startEditing(session)
    }

    /// Editing ended: what is typed is written, the layers show the head again and the note is read once more.
    private func finishEditing(_ id: NoteItemID, _ session: NoteEditingSession) async {
        _ = await session.flush(closingSession: true)
        guard let document = documents[id] else { return }
        document.unfreezeAll()
        await loadContent(id)
    }

    // MARK: Path bar and status bar

    /// Where the open note sits: its group, its title and, past the first layer, the layer shown.
    var pathComponents: [String]? {
        guard let id = tabs.current else { return nil }
        var parts: [String] = []
        let row = row(for: id)
        if let group = groups.first(where: { $0.rows.contains { $0.id == id } }) { parts.append(title(of: group)) }
        let fallback = tabs.tabs.first { $0.id == id }?.title ?? id.key.rawValue
        parts.append(row.map { presentation.pathTitle($0.summary) } ?? fallback)
        if documents[id]?.layerID == NoteDocumentModel.transcriptLayerID {
            parts.append(NoteDocumentModel.title(ofLayer: NoteDocumentModel.transcriptLayerID))
        }
        if documents[id]?.compare != nil {
            parts.append(
                String(
                    localized: "compare.title", defaultValue: "Compare",
                    comment: "Path bar: the note's versions are being compared"))
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

    // MARK: Copy and save

    /// What the path bar just did, in words for the screen and for VoiceOver.
    enum Feedback: Equatable {
        case copied
        case saved
        case saveFailed
        case createFailed
        case titleFailed
        case restored
        case restoreFailed
        case deleted
        case deleteFailed
        case copyNotRemoved
    }

    private(set) var feedback: Feedback?
    /// Changes with every `feedback`, so the view can clear a message after a moment and announce it.
    private(set) var feedbackSerial = 0

    #if DEBUG
    /// QA (`plugins.notes.qaState=saveError`): shows the save-error strip without writing anything.
    func qaShow(_ feedback: Feedback) { show(feedback) }
    #endif

    func show(_ feedback: Feedback?) {
        self.feedback = feedback
        feedbackSerial += 1
    }

    func dismissFeedback() {
        if feedback != nil { show(nil) }
    }

    /// ⌘⇧C: the Markdown of the layer on screen goes to the pasteboard with the transient and concealed markers,
    /// for this Mac only.
    func copyMarkdown() {
        guard let text = currentDocument?.markdown else { return }
        NoteClipboard.copy(text, to: environment.pasteboard)
        show(.copied)
    }

    /// Save .md…: a save panel, then the file. A cancelled panel says nothing; a failed write says so. `retry`
    /// writes to the place that just failed instead of asking again ("Try again" of the save-error strip).
    func saveMarkdown(retry: Bool = false) async {
        guard let document = currentDocument, let text = document.markdown, let summary = document.summary else {
            return
        }
        // One save panel at a time: a second ⌘S while the panel is open would stack another.
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let name = NoteMarkdownExport.fileName(summary)
        do {
            let saved =
                retry
                ? try await environment.saver.retry(text, suggestedName: name)
                : try await environment.saver.save(text, suggestedName: name)
            show(saved ? .saved : nil)
        } catch {
            show(.saveFailed)
        }
    }

    // MARK: Chrome

    func openSettings() { environment.openSettings() }
}
