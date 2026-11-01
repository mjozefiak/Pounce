import AppKit
import PounceKit
import SwiftUI

/// The panel's content: search field, result sections and the action footer. No backgrounds of its own:
/// the panel's glass shows through, and only the selected row draws a plain rounded rectangle.
struct LauncherView: View {
    let model: PanelModel
    let icons: IconCache
    let onFieldCreated: (NSTextField) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .symbolRenderingMode(.hierarchical)
                    .font(model.textSize.font(.title2))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                SearchField(model: model, onCreate: onFieldCreated)
            }
            .padding(.horizontal, 18)
            .frame(height: PanelModel.Metrics.fieldHeight)

            if let mode = model.currentPanelMode {
                Divider()
                if mode.isListMode {
                    ListModeView(model: model, mode: mode, icons: icons)
                } else {
                    mode.makeView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if model.showsResultsArea {
                Divider()
                ResultList(model: model, icons: icons)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ActionFooter(actions: model.selectedActions, textSize: model.textSize)
            }
        }
        .frame(width: PanelModel.Metrics.width, height: model.preferredHeight, alignment: .top)
        .dynamicTypeSize(model.textSize.dynamicTypeSize)
    }
}

/// The sections and rows. Focus stays in the search field, so selection changes are announced by the
/// model; the list itself is a VoiceOver container of labelled rows.
struct ResultList: View {
    let model: PanelModel
    let icons: IconCache
    var showsHeaders = true

    var body: some View {
        let indices = Dictionary(
            model.results.items.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let errorMessage = model.errorMessage {
                        ActionErrorRow(message: errorMessage, textSize: model.textSize)
                    }
                    if model.showsNoResults {
                        Text("No Results", comment: "Panel state when nothing matches the query")
                            .font(model.textSize.font(.body))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: PanelModel.Metrics.messageHeight)
                    }
                    ForEach(model.results.sections) { section in
                        if showsHeaders {
                            SectionHeader(section: section, textSize: model.textSize)
                        }
                        if case .unavailable = section.kind {
                            UnavailableRow(textSize: model.textSize, openSettings: model.openSettings)
                        }
                        ForEach(section.items) { item in
                            let index = indices[item.id] ?? 0
                            ResultRow(
                                item: item,
                                isSelected: model.selectedIndex == index,
                                textSize: model.textSize,
                                icons: icons
                            )
                            .id(item.id)
                            .onTapGesture(count: 2) {
                                model.select(index)
                                model.performPrimary()
                            }
                            .onTapGesture {
                                model.select(index)
                            }
                            .accessibilityAction {
                                model.select(index)
                                model.performPrimary()
                            }
                        }
                    }
                }
                .padding(PanelModel.Metrics.listPadding)
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.selectedIndex) { _, index in
                guard let index, model.results.items.indices.contains(index) else { return }
                proxy.scrollTo(model.results.items[index].id)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Results", comment: "Accessibility label of the panel's result list"))
    }
}

struct SectionHeader: View {
    let section: ResultSection
    let textSize: TextSize

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: section.symbolName)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text(section.title)
        }
        .font(textSize.font(.caption1, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(minHeight: PanelModel.Metrics.headerHeight * textSize.scale, alignment: .bottomLeading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A result action that failed: shown above the results until the next keystroke.
struct ActionErrorRow: View {
    let message: String
    let textSize: TextSize

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text(message)
                .font(textSize.font(.body))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: PanelModel.Metrics.messageHeight)
        .accessibilityElement(children: .combine)
    }
}

/// A plugin in the `failed` state: its section says so and links to Settings → Features.
struct UnavailableRow: View {
    let textSize: TextSize
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text("Feature unavailable", comment: "Panel row for a plugin that failed to start")
                .font(textSize.font(.body))
            Spacer(minLength: 0)
            Button {
                openSettings()
            } label: {
                Text("Open Settings", comment: "Button that opens Settings from the panel")
            }
            .buttonStyle(.link)
            .font(textSize.font(.subheadline))
        }
        .padding(.horizontal, 8)
        .frame(minHeight: PanelModel.Metrics.rowHeight * textSize.scale)
    }
}

struct ResultRow: View {
    let item: ResultItem
    let isSelected: Bool
    let textSize: TextSize
    let icons: IconCache

    @Environment(\.colorSchemeContrast) private var contrast

    private var selectedText: Color { Color(nsColor: .alternateSelectedControlTextColor) }

    var body: some View {
        HStack(spacing: 10) {
            IconView(ref: item.candidate.icon, icons: icons)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.highlighted(item.candidate, isSelected: isSelected, textSize: textSize))
                    .font(textSize.font(.body))
                    .lineLimit(textSize == .extraLarge ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: textSize == .extraLarge)
                if let subtitle = item.candidate.subtitle {
                    Text(subtitle)
                        .font(textSize.font(.subheadline))
                        .foregroundStyle(
                            isSelected ? AnyShapeStyle(selectedText.opacity(0.85)) : AnyShapeStyle(.secondary)
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: PanelModel.Metrics.rowHeight * textSize.scale)
        .foregroundStyle(isSelected ? AnyShapeStyle(selectedText) : AnyShapeStyle(.primary))
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .selectedContentBackgroundColor))
            }
        }
        .overlay {
            if isSelected, contrast == .increased {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.candidate.title))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var accessibilityValue: String {
        let kind = String(localized: item.kind)
        guard let subtitle = item.candidate.subtitle else { return kind }
        return "\(kind), \(subtitle)"
    }

    /// Matched characters are bold, and also accent-coloured when the row is not selected, so a match
    /// never depends on colour alone.
    static func highlighted(_ candidate: Candidate, isSelected: Bool, textSize: TextSize) -> AttributedString {
        let characters = Array(candidate.title)
        var result = AttributedString()
        var position = 0
        for range in candidate.match.highlightRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let lower = min(max(range.lowerBound, position), characters.count)
            let upper = min(range.upperBound, characters.count)
            guard lower < upper else { continue }
            result += AttributedString(String(characters[position..<lower]))
            var match = AttributedString(String(characters[lower..<upper]))
            match.font = textSize.font(.body, weight: .bold)
            if !isSelected {
                match.foregroundColor = .accentColor
            }
            result += match
            position = upper
        }
        result += AttributedString(String(characters[min(position, characters.count)...]))
        return result
    }
}

/// A row icon, loaded lazily off the main thread through `IconCache`.
struct IconView: View {
    let ref: PounceKit.IconRef
    let icons: IconCache
    @State private var image: NSImage?

    var body: some View {
        Group {
            if case .symbol(let name) = ref {
                Image(systemName: name)
                    .symbolRenderingMode(.hierarchical)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            } else if let image {
                Image(nsImage: image).resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
        .task(id: ref) {
            image = icons.cached(ref)
            if image == nil {
                image = await icons.image(for: ref)
            }
        }
    }
}

/// The selected row's actions, generated from `actions(for:)`: title and key as text in a capsule.
struct ActionFooter: View {
    let actions: [ResultAction]
    let textSize: TextSize

    var body: some View {
        HStack(spacing: 16) {
            Spacer(minLength: 0)
            ForEach(actions.prefix(2)) { action in
                HStack(spacing: 6) {
                    Text(action.title)
                    if let shortcut = action.shortcut {
                        Text(Self.keys(shortcut))
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                .font(textSize.font(.caption1))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: PanelModel.Metrics.footerHeight)
    }

    static func keys(_ shortcut: KeyShortcut) -> String {
        var text = ""
        if shortcut.modifiers.contains(.control) { text += "⌃" }
        if shortcut.modifiers.contains(.option) { text += "⌥" }
        if shortcut.modifiers.contains(.shift) { text += "⇧" }
        if shortcut.modifiers.contains(.command) { text += "⌘" }
        switch shortcut.key {
        case "\r": text += "⏎"
        case " ": text += "Space"
        case "\u{8}", "\u{7F}": text += "⌫"
        default: text += shortcut.key.uppercased()
        }
        return text
    }
}

/// A plugin's list panel mode (for example the clipboard history): the plugin's status area, the
/// filters, the list on the left with the selected candidate's preview on the right, and the footer.
struct ListModeView: View {
    static let listWidth: CGFloat = 320

    let model: PanelModel
    let mode: PanelMode
    let icons: IconCache

    var body: some View {
        VStack(spacing: 0) {
            mode.makeView()
            if !mode.filters.isEmpty {
                FilterBar(filters: mode.filters, selected: model.modeFilter, textSize: model.textSize) { index in
                    model.toggleFilter(at: index)
                }
                Divider()
            }
            if model.showsModeEmptyState, let makeEmpty = mode.makeEmptyView {
                makeEmpty()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ResultList(model: model, icons: icons, showsHeaders: false)
                        .frame(width: Self.listWidth)
                    Divider()
                    preview
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            ActionFooter(actions: model.selectedActions, textSize: model.textSize)
        }
    }

    @ViewBuilder private var preview: some View {
        if let item = model.selectedItem, let makePreview = mode.makePreview {
            makePreview(item.candidate)
                .id(item.id)
        } else {
            Color.clear
                .accessibilityHidden(true)
        }
    }
}

/// The list mode's filters as toggle chips, each with its Command-number shortcut.
struct FilterBar: View {
    let filters: [PanelModeFilter]
    let selected: PanelModeFilter.ID?
    let textSize: TextSize
    let toggle: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(filters.enumerated()), id: \.element.id) { index, filter in
                let isSelected = filter.id == selected
                Button {
                    toggle(index)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: filter.symbolName)
                            .symbolRenderingMode(.hierarchical)
                            .accessibilityHidden(true)
                        Text(filter.title)
                        if index < 9 {
                            Text(verbatim: "⌘\(index + 1)")
                                .monospacedDigit()
                                .foregroundStyle(
                                    isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary)
                                )
                                .accessibilityHidden(true)
                        }
                    }
                    .font(textSize.font(.caption1, weight: isSelected ? .semibold : .regular))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .background {
                        Capsule().fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityHint(Text("Command-\(index + 1)", comment: "Accessibility hint with a filter's shortcut"))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Filters", comment: "Accessibility label of the panel's filter bar"))
    }
}
