import LintelKit
import LintelUI
import SwiftUI

/// The inspector on the right of the document (prototype `.insp`): a tab strip and the pane. History and Details; Comments
/// join the strip in step 5.2.
struct NoteInspector: View {
    let model: NotesWorkspaceModel
    let document: NoteDocumentModel
    @Environment(\.lintelTextSize) private var textSize

    /// A tab of the strip (prototype `.it`): the icon, and the name in bold on the one that is on.
    private func tab(_ tab: NoteInspectorTab, symbol: String, title: Text) -> some View {
        let isOn = model.inspectorTab == tab
        return Button {
            model.selectInspectorTab(tab)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).accessibilityHidden(true)
                if isOn { title.font(textSize.font(.callout, weight: .bold)) }
            }
            .font(textSize.font(.callout))
            .foregroundStyle(isOn ? LintelBrand.accentText : LintelBrand.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isOn ? LintelBrand.windowSelectionTint : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tab(
                    .history, symbol: "clock",
                    title: Text("History", comment: "Inspector: tab with the versions of the text"))
                tab(
                    .details, symbol: "slider.horizontal.3",
                    title: Text("Details", comment: "Inspector: tab with the view toggles and the note's facts"))
                Spacer(minLength: 0)
                Button {
                    model.inspectorVisible = false
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(textSize.font(.callout))
                        .foregroundStyle(LintelBrand.secondaryText)
                        .frame(width: 26 * textSize.scale, height: 26 * textSize.scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Hide the inspector", comment: "Accessibility label of the inspector's close"))
                .help(Text("Hide the inspector", comment: "Tooltip of the inspector's close button"))
            }
            .padding(.horizontal, 10)
            .frame(height: 33.75 * textSize.scale)
            .overlay(alignment: .bottom) { LintelDivider() }
            ScrollView {
                Group {
                    switch model.inspectorTab {
                    case .history: NoteHistoryPane(model: model, document: document)
                    case .details: NoteDetailsPane(model: model, document: document)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.inspectorTab == .history { NoteHistoryFooter() }
        }
        .task(id: HistoryTaskKey(tab: model.inspectorTab, layer: document.layerID, note: document.id)) {
            if model.inspectorTab == .history { await model.loadHistory(for: document.id) }
        }
        .frame(width: min(23 * 12.5 * textSize.scale, 300))
        .background(LintelBrand.sidebarBackground)
        .overlay(alignment: .leading) { LintelDivider(axis: .vertical) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Inspector", comment: "Accessibility label of the note inspector"))
    }
}

private struct HistoryTaskKey: Equatable {
    var tab: NoteInspectorTab
    var layer: String?
    var note: NoteItemID
}

/// Details (prototype `lib-details`): the view toggles with the author legend, then what the source says about
/// the note. Every toggle writes its `plugins.notes.*` setting at once.
struct NoteDetailsPane: View {
    let model: NotesWorkspaceModel
    let document: NoteDocumentModel
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        @Bindable var preferences = model.preferences
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader(Text("View", comment: "Inspector, Details: heading of the view toggles"), first: true)
            toggleRow(
                Text("Author bars", comment: "Inspector, Details: toggle for the author bars"),
                hint: Text(
                    "Who wrote each block: AI, You, STT.", comment: "Inspector, Details: what the author bars show"),
                isOn: $preferences.showAuthorBars)
            AuthorLegend()
            toggleRow(
                Text("Source quotes", comment: "Inspector, Details: toggle for the quote chips"),
                hint: Text(
                    "Timestamps that open the transcript.", comment: "Inspector, Details: what the quote chips do"),
                isOn: $preferences.showQuotes)
            toggleRow(
                Text("Wrap lines", comment: "Inspector, Details: toggle for wrapping long lines in the editor"),
                hint: nil, isOn: $preferences.wrapLines)
            let facts = noteFacts
            if !facts.isEmpty {
                sectionHeader(Text("Note", comment: "Inspector, Details: heading of the note's facts"), first: false)
                ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(fact.label)
                            .foregroundStyle(LintelBrand.secondaryText)
                        Spacer(minLength: 0)
                        Text(verbatim: fact.value)
                            .foregroundStyle(LintelBrand.ink)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(textSize.font(.callout))
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
            actions
        }
    }

    /// Prototype `.acl`: what can be done with the note. Regenerate comes with the agent (step 6.x).
    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(Text("Actions", comment: "Inspector, Details: heading of the note's actions"), first: false)
            actionRow(
                "doc.on.doc", Text("Copy Markdown", comment: "Path bar: copies the note as Markdown"), keys: "⌘⇧C",
                tint: LintelBrand.ink
            ) { model.copyMarkdown() }
            actionRow(
                "square.and.arrow.down", Text("Save .md…", comment: "Path bar: saves the note as a Markdown file"),
                keys: nil, tint: LintelBrand.ink
            ) { Task { await model.saveMarkdown() } }
            if model.canDelete(document.id) {
                actionRow(
                    "trash", Text("Delete…", comment: "Explorer: deletes the note after a confirmation"), keys: "⌘⌫",
                    tint: LintelBrand.statusError
                ) { Task { await model.requestDelete(document.id) } }
            }
        }
    }

    private func actionRow(
        _ symbol: String, _ title: Text, keys: String?, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).accessibilityHidden(true)
                title
                Spacer(minLength: 0)
                if let keys {
                    Text(verbatim: keys)
                        .font(textSize.font(.caption1, weight: .semibold))
                        .foregroundStyle(LintelBrand.secondaryText)
                        .padding(.horizontal, 6)
                        .background(LintelBrand.fill, in: RoundedRectangle(cornerRadius: 5))
                        .accessibilityHidden(true)
                }
            }
            .font(textSize.font(.callout))
            .foregroundStyle(tint)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// What the source supplies (spec deviation 3: Details shows `NoteContent.details`), led by the app.
    private var noteFacts: [NoteDetail] {
        var facts: [NoteDetail] = []
        if let app = document.summary?.sourceApp, !app.isEmpty {
            facts.append(
                NoteDetail(
                    label: LocalizedStringResource(
                        "Source", comment: "Inspector, Details: the app a recording came from"),
                    value: app))
        }
        facts += document.content?.details ?? []
        return facts
    }

    private func sectionHeader(_ title: Text, first: Bool) -> some View {
        title
            .font(textSize.font(.caption1, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(LintelBrand.secondaryText)
            .padding(.top, first ? 2 : 14)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func toggleRow(_ title: Text, hint: Text?, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                title.font(textSize.font(.callout)).foregroundStyle(LintelBrand.ink)
                if let hint {
                    hint.font(textSize.font(.footnote)).foregroundStyle(LintelBrand.secondaryText)
                }
            }
            Spacer(minLength: 0)
            Toggle(isOn: isOn) { title }
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(LintelBrand.accent)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { LintelDivider() }
        .accessibilityElement(children: .combine)
    }
}

/// The author legend: what each bar colour means. It sits under the Author bars toggle and is read as words.
struct AuthorLegend: View {
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Self.authors, id: \.rawValue) { author in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(author.barColor).frame(width: 3, height: 12 * textSize.scale)
                    Text(verbatim: author.gutterText)
                        .font(textSize.font(.footnote).monospaced())
                        .foregroundStyle(LintelBrand.secondaryText)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: author.spokenName))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Author legend", comment: "Accessibility label of the legend of the author bars"))
    }

    nonisolated static let authors: [NoteAuthor] = [.agent, .human, .stt]
}
