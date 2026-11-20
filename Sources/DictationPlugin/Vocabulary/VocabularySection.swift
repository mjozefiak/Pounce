import LintelUI
import SwiftUI

/// The Vocabulary section of Settings → Dictation (DICT-1.2, mockup part A): the switch, the list of terms with
/// their spoken variants, and the form that adds or edits one. It sits between Basics and Advanced.
struct VocabularySection: View {
    @Bindable var model: VocabularyPanelModel
    /// `false` while the plugin is off: the main window shows the pane dimmed and nothing is read, so only the
    /// switch is drawn.
    var isActive = true

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        Section {
            if isActive {
                ForEach(notices, id: \.self) { notice in
                    VocabularyNoticeStrip(notice: notice, model: model)
                }
                if model.limitReached {
                    VocabularyStrip(
                        symbol: "info.circle", tint: LintelBrand.fill,
                        text: Text(
                            "The vocabulary is full (2,000 terms). Delete one to add another.",
                            comment: "Vocabulary section: shown when the vocabulary holds the most terms it can")
                    )
                }
            }
            switchRow
            if isActive {
                if model.showsSearch { searchRow }
                VocabularyListView(model: model)
            }
        } header: {
            header
        } footer: {
            if isActive { footer }
        }
    }

    private var notices: [VocabularyPanelModel.Notice] {
        model.notice.map { [$0] } ?? []
    }

    // MARK: Header, switch, search, footer

    private var header: some View {
        HStack {
            Text("Vocabulary", comment: "Settings → Dictation: title of the section with the user's own terms")
            Spacer()
            if isActive {
                Text(countText)
                    .font(textSize.font(.callout, weight: .regular))
                    .accessibilityLabel(countText)
            }
        }
        .settingsSectionHeader()
    }

    private var countText: String {
        model.isSearching
            ? VocabularyText.searchCount(shown: model.visibleRows.count, of: model.entries.count)
            : VocabularyText.termCount(model.entries.count)
    }

    private var switchRow: some View {
        Toggle(isOn: $model.isEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Use vocabulary", comment: "Settings → Dictation: switch that turns the user's vocabulary on")
                    .font(textSize.font(.body))
                Text(
                    "Replaces what was heard with your spelling. Works without a model.",
                    comment: "Settings → Dictation: help under the Use vocabulary switch"
                )
                .font(textSize.font(.callout))
                .foregroundStyle(LintelBrand.secondaryText)
            }
        }
        .toggleStyle(.switch)
        .disabled(!isActive)
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LintelBrand.secondaryText)
                .accessibilityHidden(true)
            TextField(
                text: $model.query,
                prompt: Text("Search terms", comment: "Vocabulary section: placeholder of the search field")
            ) {
                Text("Search terms", comment: "Vocabulary section: placeholder of the search field")
            }
            .textFieldStyle(.plain)
            .font(textSize.font(.body))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(LintelBrand.fill, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.entries.isEmpty || model.editor != nil {
                Button {
                    model.beginAdding()
                } label: {
                    Label {
                        Text("Add Term…", comment: "Vocabulary section: button that opens the form for a new term")
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
                .buttonStyle(LintelSecondaryButtonStyle())
                .disabled(!model.canAdd)
            }
            if !model.isEnabled {
                SettingsFooter(
                    LocalizedStringResource(
                        "Off: terms are kept and not used.",
                        comment: "Vocabulary section: note under the list while the switch is off"))
            }
        }
    }
}

// MARK: - Strips

/// A tinted line with an icon (prototype `.strip`).
struct VocabularyStrip<Actions: View>: View {
    let symbol: String
    let tint: Color
    let text: Text
    var iconTint: Color = LintelBrand.secondaryText
    @ViewBuilder var actions: Actions

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(iconTint)
                .accessibilityHidden(true)
            text
                .font(textSize.font(.callout))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

extension VocabularyStrip where Actions == EmptyView {
    init(symbol: String, tint: Color, text: Text, iconTint: Color = LintelBrand.secondaryText) {
        self.init(symbol: symbol, tint: tint, text: text, iconTint: iconTint, actions: { EmptyView() })
    }
}

/// The notice about the file (D12): a newer version, an unreadable file, or the one-time "started a new one".
struct VocabularyNoticeStrip: View {
    let notice: VocabularyPanelModel.Notice
    @Bindable var model: VocabularyPanelModel

    var body: some View {
        switch notice {
        case .newerVersion:
            VocabularyStrip(
                symbol: "lock", tint: LintelBrand.fill,
                text: Text(
                    "This vocabulary was saved by a newer Lintel. It is used, but can’t be changed here.",
                    comment: "Vocabulary section: notice when the file comes from a newer version"))
        case .unreadable:
            VocabularyStrip(
                symbol: "lock", tint: LintelBrand.fill,
                text: Text(
                    "The vocabulary file couldn’t be read. It is left as it is and can’t be changed here.",
                    comment: "Vocabulary section: notice when the file exists but cannot be read"))
        case .setAside:
            VocabularyStrip(
                symbol: "exclamationmark.triangle", tint: LintelBrand.statusAttention.opacity(0.11),
                text: Text(
                    "The vocabulary file was damaged, so Lintel started a new one. A copy of the old file was kept.",
                    comment: "Vocabulary section: one-time notice after a damaged file was set aside"),
                iconTint: LintelBrand.statusAttention
            ) {
                Button {
                    model.showCopyInFinder()
                } label: {
                    Text(
                        "Show Copy in Finder",
                        comment: "Vocabulary section: button that reveals the kept copy of a damaged file")
                }
                .buttonStyle(.plain)
                .foregroundStyle(LintelBrand.accentText)
                Button {
                    model.dismissNotice()
                } label: {
                    Text("Dismiss", comment: "Button that closes a one-time notice")
                }
                .buttonStyle(.plain)
                .foregroundStyle(LintelBrand.accentText)
            }
        }
    }
}

// MARK: - List

/// The rows, the form in the place of the row being edited, the empty states and the delete confirmation.
struct VocabularyListView: View {
    @Bindable var model: VocabularyPanelModel

    @Environment(\.lintelTextSize) private var textSize
    @FocusState private var listFocused: Bool

    /// The list's height before it scrolls: about six rows (prototype `.scrollbox`, 15.4 em).
    private var scrollLimit: CGFloat { 200 * textSize.scale }

    var body: some View {
        content
            .destructiveConfirmation(
                isPresented: Binding(
                    get: { model.pendingDeletion != nil },
                    set: { if !$0, model.pendingDeletion != nil { model.cancelDelete() } }),
                deletion,
                onConfirm: { model.confirmDelete() }
            )
            .onChange(of: model.listFocusTick) { listFocused = true }
            .onAppear {
                guard model.focusListOnAppear else { return }
                model.focusListOnAppear = false
                DispatchQueue.main.async { listFocused = true }
            }
    }

    private var deletion: DestructiveConfirmation {
        let term = model.pendingDeletion?.term ?? ""
        let variants = model.pendingDeletion?.aliases.count ?? 0
        return DestructiveConfirmation(
            prompt: LocalizedStringResource(
                "Delete “\(term)”?", comment: "Confirmation sheet title when a vocabulary term is deleted"),
            detail: variants == 0
                ? LocalizedStringResource(
                    "This can’t be undone.",
                    comment: "Confirmation sheet detail when a vocabulary term without variants is deleted")
                : LocalizedStringResource(
                    "Its \(variants) spoken variants are removed too. This can’t be undone.",
                    comment:
                        "Confirmation sheet detail when a vocabulary term is deleted; the number is how many spoken variants go with it"
                ),
            confirmTitle: LocalizedStringResource("Delete", comment: "Button that confirms a deletion"))
    }

    @ViewBuilder private var content: some View {
        let rows = model.visibleRows
        if rows.isEmpty, model.editor == nil {
            emptyState
        } else {
            list(rows)
        }
    }

    @ViewBuilder private func list(_ rows: [VocabularyPanelModel.Row]) -> some View {
        let formOpen = model.editor != nil
        let stack = ScrollViewReader { proxy in
            ScrollView {
                rowsStack(rows)
                    .padding(.vertical, 2)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: formOpen ? nil : scrollLimit)
            .onChange(of: model.scrollTick) {
                guard let id = model.highlightedID ?? model.selectedID else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
        stack
            .focusable(model.editor == nil)
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { handle { model.moveSelection(by: -1) } }
            .onKeyPress(.downArrow) { handle { model.moveSelection(by: 1) } }
            .onKeyPress(.return) { handle { model.editSelected() } }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in handle { model.deleteSelected() } }
            .onChange(of: listFocused) {
                if listFocused, model.selectedID == nil, let first = model.visibleRows.first {
                    model.selectedID = first.id
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                Text("Vocabulary", comment: "Settings → Dictation: title of the section with the user's own terms"))
    }

    private func handle(_ action: () -> Void) -> KeyPress.Result {
        guard model.editor == nil, model.pendingDeletion == nil, model.selectedID != nil || !model.visibleRows.isEmpty
        else { return .ignored }
        action()
        return .handled
    }

    @ViewBuilder private func rowsStack(_ rows: [VocabularyPanelModel.Row]) -> some View {
        let useLazy = rows.count > 80
        let inner = Group {
            if case .adding? = model.editor?.target {
                VocabularyFormView(model: model)
                if !rows.isEmpty { LintelDivider() }
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                if case .editing(let id)? = model.editor?.target, id == row.id {
                    VocabularyFormView(model: model)
                } else {
                    VocabularyRowView(
                        row: row, position: offset + 1, total: rows.count,
                        isSelected: listFocused && model.selectedID == row.id,
                        isHighlighted: model.highlightedID == row.id, query: model.isSearching ? model.query : "",
                        showsActions: model.canEdit, isDimmed: !model.isEnabled,
                        edit: { model.beginEditing(row.id) }, delete: { model.requestDelete(row.id) },
                        select: {
                            model.selectedID = row.id
                            listFocused = true
                        }
                    )
                    .id(row.id)
                }
                if offset < rows.count - 1 { LintelDivider() }
            }
        }
        if useLazy {
            LazyVStack(alignment: .leading, spacing: 0) { inner }
                .frame(height: model.editor == nil ? scrollLimit : nil, alignment: .top)
        } else {
            VStack(alignment: .leading, spacing: 0) { inner }
        }
    }

    // MARK: Empty states

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 4) {
            if model.isSearching {
                let query = VocabularyRules.tidy(model.query)
                Text(
                    "No terms match “\(query)”.",
                    comment: "Vocabulary section: nothing found; the argument is the search text"
                )
                .font(textSize.font(.body, weight: .semibold))
                Text(
                    "Search covers terms and spoken variants.",
                    comment: "Vocabulary section: what the search looks in"
                )
                .font(textSize.font(.callout))
                .foregroundStyle(LintelBrand.secondaryText)
                Button {
                    model.beginAdding(term: query)
                } label: {
                    Label {
                        Text(
                            "Add “\(query)”…",
                            comment: "Vocabulary section: button that adds the searched text as a new term")
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
                .buttonStyle(LintelSecondaryButtonStyle())
                .disabled(!model.canAdd)
                .padding(.top, 6)
            } else {
                Text("No terms yet", comment: "Vocabulary section: title of the empty list")
                    .font(textSize.font(.body, weight: .semibold))
                Text(
                    "Add names and identifiers that dictation gets wrong, for example “auth service” → AuthService.",
                    comment: "Vocabulary section: explanation under the empty list"
                )
                .font(textSize.font(.callout))
                .foregroundStyle(LintelBrand.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.beginAdding()
                } label: {
                    Label {
                        Text("Add Term…", comment: "Vocabulary section: button that opens the form for a new term")
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
                .buttonStyle(LintelPrimaryButtonStyle())
                .disabled(!model.canAdd)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Row

/// One term: the term, its spoken variants as pills below it, and Edit and Delete at the right. For VoiceOver the
/// row is one element with its position and two actions; the icons are for the pointer.
struct VocabularyRowView: View {
    let row: VocabularyPanelModel.Row
    let position: Int
    let total: Int
    let isSelected: Bool
    let isHighlighted: Bool
    let query: String
    let showsActions: Bool
    let isDimmed: Bool
    let edit: () -> Void
    let delete: () -> Void
    let select: () -> Void

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(highlighted(row.term))
                    .font(textSize.font(.body, weight: .semibold))
                if !row.aliases.isEmpty {
                    WrappingLayout(horizontalSpacing: 5, verticalSpacing: 4) {
                        ForEach(Array(row.aliases.enumerated()), id: \.offset) { _, alias in
                            Text(highlighted(alias))
                                .font(textSize.font(.callout))
                                .foregroundStyle(LintelBrand.ink)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1)
                                .background(LintelBrand.fill, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isDimmed ? 0.55 : 1)
            if showsActions {
                HStack(spacing: 2) {
                    iconButton("pencil", action: edit)
                    iconButton("trash", action: delete)
                }
                .accessibilityHidden(true)
                .opacity(isDimmed ? 0.55 : 1)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 2)
        .background {
            if isSelected || isHighlighted {
                LintelBrand.windowSelectionTint
                    .overlay(alignment: .leading) {
                        Rectangle().fill(LintelBrand.accent).frame(width: 3).padding(.vertical, 7)
                    }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VocabularyText.rowLabel(term: row.term, aliases: row.aliases))
        .accessibilityValue(VocabularyText.rowPosition(position, of: total))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityActions {
            if showsActions {
                Button(action: edit) { Text("Edit Term", comment: "VoiceOver action on a vocabulary row") }
                Button(action: delete) { Text("Delete Term", comment: "VoiceOver action on a vocabulary row") }
            }
        }
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(textSize.font(.callout))
                .foregroundStyle(LintelBrand.secondaryText)
                .frame(width: 28 * textSize.scale, height: 28 * textSize.scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    /// The text with the search's matches marked (prototype `mark`: tint behind accent text).
    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let wanted = VocabularyRules.tidy(query)
        guard !wanted.isEmpty else { return result }
        var start = text.startIndex
        while start < text.endIndex,
            let found = text.range(
                of: wanted, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex)
        {
            if let range = Range(found, in: result) {
                result[range].backgroundColor = LintelBrand.windowSelectionTint
                result[range].foregroundColor = LintelBrand.accentText
                result[range].inlinePresentationIntent = .stronglyEmphasized
            }
            start = found.upperBound
        }
        return result
    }
}
