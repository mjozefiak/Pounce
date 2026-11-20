import Foundation
import Observation
import SwiftUI

/// What the Vocabulary section shows and does (DICT-1.2, part A of the mockup): the list of terms, the search, the
/// form that adds or edits one, the confirmation for a delete and the notices about the file. It owns no file
/// access: `VocabularyStore` reads and writes. Terms and variants are never logged.
@MainActor @Observable
final class VocabularyPanelModel {
    struct Row: Identifiable, Equatable {
        /// The index in the store's order; the list shows the rows alphabetically.
        let id: Int
        let term: String
        let aliases: [String]
    }

    enum Target: Equatable {
        case adding
        case editing(Int)
    }

    enum Field: Equatable {
        case term
        case aliases
    }

    /// The open form.
    struct Editor: Equatable {
        var target: Target
        var term = ""
        var aliases: [String] = []
        /// What is typed in the variants field and not yet a token.
        var pending = ""
        var termProblem: VocabularyRules.TermProblem?
        var aliasProblem: VocabularyRules.AliasProblem?
        /// The variant the error is about, so its token is drawn in the error colour.
        var badAlias: String?
        /// Short variants the user ticked "use anyway" for, as comparison keys.
        var acknowledged: Set<String> = []
        /// Short variants the entry already had when it was opened; they ask nothing again.
        var inherited: Set<String> = []
        var saveFailed = false
        var focus = Field.term
        /// Counts requests to move the focus, so asking for the same field twice still moves it.
        var focusTick = 0

        static func == (lhs: Editor, rhs: Editor) -> Bool {
            lhs.target == rhs.target && lhs.term == rhs.term && lhs.aliases == rhs.aliases
                && lhs.pending == rhs.pending && lhs.termProblem == rhs.termProblem
                && lhs.aliasProblem == rhs.aliasProblem && lhs.badAlias == rhs.badAlias
                && lhs.acknowledged == rhs.acknowledged && lhs.saveFailed == rhs.saveFailed
                && lhs.focus == rhs.focus && lhs.focusTick == rhs.focusTick
        }
    }

    /// A one-time or lasting note above the list about the file (D12).
    enum Notice: Equatable {
        /// The file came from a newer Lintel: terms are used, not changed here.
        case newerVersion
        /// The file could not be read; it is left alone.
        case unreadable
        /// The file was damaged and a copy was kept; dismissable.
        case setAside
    }

    // MARK: State

    private(set) var entries: [VocabularyStore.Term] = []
    var query = ""
    private(set) var editor: Editor?
    /// The row the keyboard is on.
    var selectedID: Int?
    /// The row "Show" pointed to; cleared on the next change of the list.
    private(set) var highlightedID: Int?
    /// Counts requests to scroll to `highlightedID` or the selected row.
    private(set) var scrollTick = 0
    var pendingDeletion: Row?
    private(set) var noticeDismissed = false
    /// Where the keyboard goes after a form or a sheet closes: back to the list.
    private(set) var listFocusTick = 0

    /// QA: the list takes the keyboard when it first appears, so a screenshot shows the selected row.
    var focusListOnAppear = false

    var isEnabled: Bool {
        didSet { if isEnabled != oldValue { settings.setVocabularyEnabled(isEnabled) } }
    }

    @ObservationIgnored private let store: VocabularyStore
    @ObservationIgnored private let settings: DictationSettings
    @ObservationIgnored private let revealInFinder: @MainActor (URL) -> Void
    /// VoiceOver announcements; tests replace it.
    @ObservationIgnored var announce: @MainActor (String) -> Void = { text in
        AccessibilityNotification.Announcement(text).post()
    }

    init(
        store: VocabularyStore, settings: DictationSettings,
        revealInFinder: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        self.store = store
        self.settings = settings
        self.revealInFinder = revealInFinder
        isEnabled = settings.vocabularyEnabled
        entries = store.terms
    }

    /// Reads what the store holds (it is loaded on activation) and the switch.
    func reload() {
        entries = store.terms
        isEnabled = settings.vocabularyEnabled
        if let id = selectedID, !entries.indices.contains(id) { selectedID = nil }
    }

    // MARK: List

    var isReadOnly: Bool { store.isReadOnly }
    var canEdit: Bool { !store.isReadOnly }
    var limitReached: Bool { entries.count >= VocabularyStore.maximumTerms }
    /// The Add Term button is inactive while a form is open, in a read-only file and when the list is full.
    var canAdd: Bool { editor == nil && canEdit && !limitReached }
    var showsSearch: Bool { entries.count >= VocabularyRules.searchThreshold }
    private var activeQuery: String { showsSearch ? query : "" }
    var isSearching: Bool { !VocabularyRules.tidy(activeQuery).isEmpty }

    var allRows: [Row] {
        VocabularyRules.sortedIndices(of: entries).map {
            Row(id: $0, term: entries[$0].term, aliases: entries[$0].aliases)
        }
    }

    /// The rows shown: all of them, or the matches of the search.
    var visibleRows: [Row] {
        let rows = allRows
        guard isSearching else { return rows }
        return rows.filter { VocabularyRules.matches(entries[$0.id], query: activeQuery) }
    }

    var notice: Notice? {
        switch store.condition {
        case .normal: return nil
        case .newerVersion: return .newerVersion
        case .unreadable: return .unreadable
        case .setAside: return noticeDismissed ? nil : .setAside
        }
    }

    func dismissNotice() { noticeDismissed = true }

    func showCopyInFinder() { revealInFinder(store.corruptCopyURL) }

    // MARK: Keyboard on the list

    func moveSelection(by step: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selectedID }
        let next = current.map { min(max($0 + step, 0), rows.count - 1) } ?? (step > 0 ? 0 : rows.count - 1)
        selectedID = rows[next].id
        scrollTick += 1
    }

    func editSelected() {
        guard let id = selectedID else { return }
        beginEditing(id)
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        requestDelete(id)
    }

    // MARK: Form

    func beginAdding(term: String = "") {
        guard canAdd else { return }
        var form = Editor(target: .adding)
        form.term = term
        form.focus = term.isEmpty ? .term : .aliases
        editor = form
        pendingDeletion = nil
    }

    func beginEditing(_ id: Int) {
        guard canEdit, entries.indices.contains(id) else { return }
        let entry = entries[id]
        var form = Editor(target: .editing(id))
        form.term = entry.term
        form.aliases = entry.aliases
        form.inherited = Set(VocabularyRules.shortAliases(entry.aliases).map(VocabularyRules.key))
        form.focus = .aliases
        editor = form
        selectedID = id
    }

    /// Fills the open form (QA and tests): the term, the tokens and the typed text.
    func fill(term: String, aliases: [String], pending: String = "") {
        guard editor != nil else { return }
        editor?.term = term
        editor?.aliases = aliases
        editor?.pending = pending
        editor?.termProblem = nil
        editor?.aliasProblem = nil
        editor?.badAlias = nil
        editor?.saveFailed = false
    }

    func cancelEditing() {
        guard let form = editor else { return }
        editor = nil
        if case .editing(let id) = form.target { selectedID = id }
        listFocusTick += 1
    }

    func setTerm(_ text: String) {
        guard editor != nil else { return }
        editor?.term = text
        editor?.termProblem = nil
        editor?.saveFailed = false
    }

    func setPending(_ text: String) {
        guard editor != nil else { return }
        editor?.pending = text
        editor?.aliasProblem = nil
        editor?.badAlias = nil
        editor?.saveFailed = false
    }

    /// Return in the variants field: a typed variant becomes a token; an empty field saves (D13).
    func returnInAliases() {
        guard var form = editor else { return }
        if VocabularyRules.tidy(form.pending).isEmpty {
            submit()
        } else {
            commitPending(into: &form)
            editor = form
        }
    }

    /// Return in the term field moves on to the variants.
    func returnInTerm() {
        guard editor != nil else { return }
        editor?.focus = .aliases
        editor?.focusTick += 1
    }

    private func commitPending(into form: inout Editor) {
        let text = VocabularyRules.tidy(form.pending)
        form.pending = ""
        guard !text.isEmpty else { return }
        let textKey = VocabularyRules.key(text)
        let known = Set(form.aliases.map(VocabularyRules.key))
        // A variant given twice, or equal to the term, is the same variant.
        if !known.contains(textKey) { form.aliases.append(text) }
        form.aliasProblem = nil
        form.badAlias = nil
    }

    /// Backspace in an empty variants field removes the last token (D4).
    func removeLastAlias() {
        guard var form = editor, !form.aliases.isEmpty else { return }
        form.aliases.removeLast()
        form.aliasProblem = nil
        form.badAlias = nil
        editor = form
    }

    func removeAlias(at index: Int) {
        guard var form = editor, form.aliases.indices.contains(index) else { return }
        form.aliases.remove(at: index)
        form.aliasProblem = nil
        form.badAlias = nil
        editor = form
    }

    // MARK: Short variants (D8)

    /// Every variant the form would save, the typed one included.
    var effectiveAliases: [String] {
        guard let form = editor else { return [] }
        let all = VocabularyRules.tidy(form.pending).isEmpty ? form.aliases : form.aliases + [form.pending]
        return VocabularyRules.cleanedAliases(all, term: form.term)
    }

    /// The short variants that still need the user's "use anyway".
    var unconfirmedShortAliases: [String] {
        guard let form = editor else { return [] }
        return VocabularyRules.shortAliases(effectiveAliases).filter {
            !form.inherited.contains(VocabularyRules.key($0))
        }
    }

    var shortAliasesAreConfirmed: Bool {
        guard let form = editor else { return false }
        return unconfirmedShortAliases.allSatisfy { form.acknowledged.contains(VocabularyRules.key($0)) }
    }

    func setShortAliasesConfirmed(_ confirmed: Bool) {
        guard editor != nil else { return }
        let keys = Set(unconfirmedShortAliases.map(VocabularyRules.key))
        if confirmed {
            editor?.acknowledged.formUnion(keys)
        } else {
            editor?.acknowledged.subtract(keys)
        }
    }

    /// The one place where the button is inactive (D8): a short variant that is not confirmed yet.
    var canSubmit: Bool { editor != nil && shortAliasesAreConfirmed }

    /// The example under the variants (D5), built by the real replacer; `nil` without a term and a variant.
    var example: (heard: String, inserted: String, term: String)? {
        guard let form = editor else { return nil }
        return VocabularyRules.example(
            term: form.term, aliases: effectiveAliases, sentence: VocabularyText.exampleSentence)
    }

    // MARK: Save

    /// Add or Save: checks, then writes. A problem stays in the form, next to its field, with the focus on it
    /// (D6); the button is always active except for an unconfirmed short variant.
    func submit() {
        guard var form = editor, canSubmit else { return }
        commitPending(into: &form)
        form.term = VocabularyRules.tidy(form.term)
        form.aliases = VocabularyRules.cleanedAliases(form.aliases, term: form.term)
        form.saveFailed = false
        let ignoring: Int?
        if case .editing(let id) = form.target { ignoring = id } else { ignoring = nil }
        let check = VocabularyRules.check(term: form.term, aliases: form.aliases, ignoring: ignoring, in: entries)
        form.termProblem = check.term
        form.aliasProblem = check.alias?.problem
        form.badAlias = check.alias?.text
        guard check.isValid else {
            form.focus = check.term != nil ? .term : .aliases
            form.focusTick += 1
            editor = form
            announce(message(for: form) ?? "")
            return
        }
        if case .adding = form.target, limitReached {
            editor = form
            return
        }
        var updated = entries
        let saved = VocabularyStore.Term(term: form.term, aliases: form.aliases)
        let savedID: Int
        switch form.target {
        case .adding:
            updated.append(saved)
            savedID = updated.count - 1
        case .editing(let id):
            guard updated.indices.contains(id) else {
                editor = nil
                return
            }
            updated[id] = saved
            savedID = id
        }
        do {
            try store.save(updated)
        } catch {
            form.saveFailed = true
            editor = form
            announce(VocabularyText.saveFailed())
            return
        }
        entries = updated
        editor = nil
        selectedID = savedID
        highlightedID = nil
        if case .adding = form.target {
            // The new entry moves to its alphabetical place; a search that hides it is cleared.
            if isSearching, !VocabularyRules.matches(saved, query: activeQuery) { query = "" }
            announce(VocabularyText.termAdded(total: entries.count))
        } else {
            announce(VocabularyText.termSaved(saved.term))
        }
        scrollTick += 1
        listFocusTick += 1
    }

    /// The text of the problem a form shows next to its field.
    func message(for form: Editor) -> String? {
        if let problem = form.termProblem {
            switch problem {
            case .empty: return VocabularyText.termEmpty()
            case .duplicate(let existing): return VocabularyText.termDuplicate(existing)
            case .isVariant(let owner): return VocabularyText.termIsVariant(form.term, owner: owner)
            }
        }
        if let problem = form.aliasProblem, let alias = form.badAlias {
            switch problem {
            case .tooLong: return VocabularyText.aliasTooLong()
            case .noWord: return VocabularyText.aliasNoWord(alias)
            case .belongsTo(let term): return VocabularyText.aliasBelongsTo(alias, term: term)
            case .isTerm(let other): return VocabularyText.aliasIsTerm(alias, other: other, term: form.term)
            }
        }
        return nil
    }

    var termMessage: String? {
        guard let form = editor, form.termProblem != nil else { return nil }
        return message(for: form)
    }

    var aliasMessage: String? {
        guard let form = editor, form.termProblem == nil, form.aliasProblem != nil else { return nil }
        return message(for: form)
    }

    /// The term that already has the entered text: "Show" (D7.1a) points at it.
    var duplicateRowID: Int? {
        guard let form = editor, case .duplicate(let existing)? = form.termProblem else { return nil }
        return entries.firstIndex { $0.term == existing }
    }

    /// "Show": clears the search, marks the existing entry and scrolls to it; the form stays open.
    func showDuplicate() {
        guard let id = duplicateRowID else { return }
        query = ""
        selectedID = id
        highlightedID = id
        scrollTick += 1
    }

    // MARK: Delete

    func requestDelete(_ id: Int) {
        guard canEdit, entries.indices.contains(id) else { return }
        let entry = entries[id]
        selectedID = id
        pendingDeletion = Row(id: id, term: entry.term, aliases: entry.aliases)
    }

    func cancelDelete() {
        pendingDeletion = nil
        listFocusTick += 1
    }

    func confirmDelete() {
        guard let row = pendingDeletion else { return }
        pendingDeletion = nil
        guard entries.indices.contains(row.id), entries[row.id].term == row.term else { return }
        var updated = entries
        updated.remove(at: row.id)
        do {
            try store.save(updated)
        } catch {
            announce(VocabularyText.saveFailed())
            return
        }
        entries = updated
        selectedID = nil
        highlightedID = nil
        // A form open on a later entry points at another index now: close it rather than edit the wrong one.
        if case .editing? = editor?.target { editor = nil }
        announce(VocabularyText.termDeleted(row.term))
        listFocusTick += 1
    }
}
