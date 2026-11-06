import LintelKit
import LintelUI
import SwiftUI

/// The explorer (prototype `.ex`): the "Notes N" label with the grouping menu, the groups with their rows, and
/// the Settings link at the bottom. Rows and groups carry text for VoiceOver; arrow keys move the selection.
struct ExplorerView: View {
    let model: NotesWorkspaceModel
    @Environment(\.lintelTextSize) private var textSize

    private var width: CGFloat { min(19 * 12.5 * textSize.scale, 250) }

    var body: some View {
        VStack(spacing: 0) {
            ExplorerSearchField(model: model)
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.isSearching, model.rows.isEmpty, let query = model.searchQuery {
                        ExplorerNoResults(query: query.raw)
                    }
                    if model.isSearching {
                        ForEach(model.rows) { row in
                            ExplorerRowView(model: model, row: row)
                        }
                    }
                    ForEach(model.groups) { group in
                        ExplorerGroupView(model: model, group: group)
                    }
                    if model.hasMore {
                        Color.clear.frame(height: 1).task { await model.loadMore() }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: .infinity)
            .accessibilityLabel(Text("Notes list", comment: "Accessibility label of the explorer's list"))
            footer
        }
        .frame(width: width)
        .background(LintelBrand.sidebarBackground)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Notes", comment: "Explorer: label above the list")
                .font(textSize.font(.callout, weight: .semibold))
            Text(verbatim: "\(model.total)")
                .font(textSize.font(.callout, weight: .semibold))
                .opacity(0.7)
                .accessibilityLabel(
                    Text("\(model.total) notes", comment: "Accessibility: how many notes the list holds"))
            Spacer(minLength: 0)
            groupingMenu
        }
        .foregroundStyle(LintelBrand.secondaryText)
        .padding(.horizontal, 14 * textSize.scale)
        .padding(.top, 12 * textSize.scale)
        .padding(.bottom, 4 * textSize.scale)
    }

    private var groupingMenu: some View {
        Menu {
            Picker(selection: Binding(get: { model.grouping }, set: { model.grouping = $0 })) {
                Text("By Time", comment: "Explorer: group the notes by time").tag(NoteGrouping.time)
                Text("By Source", comment: "Explorer: group the notes by where they come from").tag(NoteGrouping.source)
            } label: {
                Text("Group Notes", comment: "Explorer: label of the grouping choice")
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "chevron.down")
                .font(textSize.font(.caption1, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Group notes", comment: "Accessibility label of the explorer's grouping menu"))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            LintelDivider()
            Button(action: model.openSettings) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                    Text("Settings", comment: "Explorer: opens Settings")
                    Spacer(minLength: 0)
                    Text(verbatim: "⌘,")
                        .font(textSize.font(.caption1, weight: .semibold))
                        .padding(.horizontal, 6)
                        .background(LintelBrand.fill, in: RoundedRectangle(cornerRadius: 5))
                }
                .font(textSize.font(.callout))
                .foregroundStyle(LintelBrand.secondaryText)
                .padding(.horizontal, 14 * textSize.scale)
                .padding(.vertical, 8 * textSize.scale)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Settings", comment: "Explorer: opens Settings"))
            .accessibilityHint(
                Text("Opens Lintel Settings", comment: "Accessibility hint of the explorer's Settings link"))
        }
    }
}

/// One group: a caret row that collapses it, then its rows.
struct ExplorerGroupView: View {
    let model: NotesWorkspaceModel
    let group: NoteGroup
    @Environment(\.lintelTextSize) private var textSize

    private var isCollapsed: Bool { model.collapsed.contains(group.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if isCollapsed { model.collapsed.remove(group.key) } else { model.collapsed.insert(group.key) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .rotationEffect(isCollapsed ? .degrees(-90) : .zero)
                        .font(textSize.font(.caption2, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(verbatim: model.title(of: group))
                    Spacer(minLength: 0)
                    Text(verbatim: "\(group.rows.count)").fontWeight(.regular)
                }
                .font(textSize.font(.footnote, weight: .semibold))
                .foregroundStyle(LintelBrand.secondaryText)
                .padding(.horizontal, 14 * textSize.scale)
                .padding(.top, 6 * textSize.scale)
                .padding(.bottom, 2 * textSize.scale)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "\(model.title(of: group)), \(group.rows.count)"))
            .accessibilityValue(
                isCollapsed
                    ? Text("Collapsed", comment: "Accessibility value of a collapsed explorer group")
                    : Text("Expanded", comment: "Accessibility value of an expanded explorer group")
            )
            .accessibilityHint(
                Text("Shows or hides the notes of this group", comment: "Accessibility hint of an explorer group"))
            if !isCollapsed {
                ForEach(group.rows) { row in
                    ExplorerRowView(model: model, row: row)
                }
            }
        }
    }
}

/// One note in the explorer (prototype `.tr2`): the state dot, the title, the second line and, for a note that
/// needs attention or is being worked on, the state in words.
struct ExplorerRowView: View {
    let model: NotesWorkspaceModel
    let row: NoteRow
    @Environment(\.lintelTextSize) private var textSize

    private var isSelected: Bool { model.currentID == row.id }

    var body: some View {
        let level = NoteRowPresentation.level(row.badge)
        let state = NoteRowPresentation.stateText(row.badge)
        let showsDate = model.showsDate(row)
        Button {
            model.open(row.id)
        } label: {
            HStack(alignment: .top, spacing: 9 * textSize.scale) {
                Circle()
                    .fill(level.color)
                    .frame(width: 7 * textSize.scale, height: 7 * textSize.scale)
                    .padding(.top, 5 * textSize.scale)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: model.title(of: row))
                        .font(textSize.font(.callout, weight: .medium))
                        .foregroundStyle(isSelected ? LintelBrand.accentText : LintelBrand.ink)
                        .lineLimit(1)
                    if let snippet = model.snippetText(of: row) {
                        Text(HighlightedSnippet.make(snippet, query: model.searchQuery?.raw ?? ""))
                            .font(textSize.font(.footnote))
                            .foregroundStyle(LintelBrand.secondaryText)
                            .lineLimit(2)
                    } else {
                        Text(verbatim: model.presentation.subtitle(row.summary, showsDate: showsDate))
                            .font(textSize.font(.footnote))
                            .foregroundStyle(LintelBrand.secondaryText)
                            .lineLimit(1)
                    }
                    if let state {
                        Text(verbatim: state)
                            .font(textSize.font(.footnote))
                            .foregroundStyle(level == .active ? LintelBrand.accentText : LintelBrand.secondaryText)
                            .lineLimit(1)
                            .padding(.top, 1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10 * textSize.scale)
            .padding(.vertical, 6 * textSize.scale)
            .background(
                isSelected ? LintelBrand.windowSelectionTint : Color.clear, in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6 * textSize.scale)
        .padding(.vertical, 1)
        .accessibilityLabel(
            Text(
                verbatim: model.presentation.accessibilityLabel(
                    row, showsDate: showsDate, snippet: model.snippetText(of: row)))
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(Text("Opens the note in a tab", comment: "Accessibility hint of an explorer row"))
    }
}

/// A search hit's snippet with the query's words marked (prototype `mark`: the selection tint, accent text, bold).
enum HighlightedSnippet {
    @MainActor
    static func make(_ snippet: String, query: String) -> AttributedString {
        var text = AttributedString(snippet)
        for range in NoteRowPresentation.highlightRanges(in: snippet, query: query) {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                let upper = AttributedString.Index(range.upperBound, within: text)
            else { continue }
            text[lower..<upper].backgroundColor = LintelBrand.windowSelectionTint
            text[lower..<upper].foregroundColor = LintelBrand.accentText
            text[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return text
    }
}
