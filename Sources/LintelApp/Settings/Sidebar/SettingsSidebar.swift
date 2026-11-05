import LintelKit
import LintelUI
import SwiftUI

/// The Settings sidebar of the main window (prototype `.side`): inset rounded rows in the five groups of
/// `SettingsSidebarModel`, no sidebar material and no glass in Settings. The selected row is tinted with
/// `windowSelectionTint` and its label and icon are in `accentText`; other icons are `secondaryText`. The sidebar
/// fill is `sidebarBackground` (prototype `--side`). Disabled plugins stay in
/// place, dimmed and spoken as "Off"; a pane that needs attention carries a dot whose meaning is in the row's
/// accessibility label. The arrow keys move the selection in `SettingsSidebarModel.focusOrder`.
struct SettingsSidebar: View {
    let sections: [SettingsSidebarModel.Section]
    let selection: String
    let onSelect: (String) -> Void
    /// Returns to the Workspace; `nil` while no workspace section exists, which hides the row.
    let onBack: (() -> Void)?

    @Environment(\.lintelTextSize) private var textSize
    @FocusState private var isFocused: Bool

    /// The prototype's `.side` width (19 em of 13 pt, at most 250) at Medium.
    static let width: CGFloat = 248
    /// Room for the traffic lights of the transparent title bar above the first row.
    static let titleBarInset: CGFloat = 34
    /// A row's inset from the sidebar's edges (prototype `.si`, margin 8).
    static let rowInset: CGFloat = 8
    /// A row's padding (prototype `.si`, padding 5 × 8), its height at Medium (18.85 pt of text plus the padding)
    /// and the gap between rows (margin 1 + 1): a row pitch of 31 pt.
    static let rowPadding = EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)
    static let rowHeight: CGFloat = 29
    static let rowGap: CGFloat = 2
    static let rowCornerRadius: CGFloat = 7
    /// A group label's inset (prototype `.sg`, padding 10 14 3).
    static let groupLabelInsets = EdgeInsets(top: 10, leading: 14, bottom: 3, trailing: 14)
    /// The gap that stands for the Models and Advanced groups, which have no label.
    static let untitledGroupGap: CGFloat = 8

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.rowGap) {
                if let onBack {
                    rowButton(
                        title: String(
                            localized: "Back to Workspace", comment: "Settings sidebar: returns to the workspace"),
                        symbol: "chevron.left", isSelected: false, action: onBack
                    ) {
                        EmptyView()
                    }
                    .accessibilityIdentifier("settings.back")
                }
                ForEach(sections) { section in
                    if section.showsTitle {
                        Text(section.title)
                            .font(textSize.font(.subheadline, weight: .semibold))
                            .foregroundStyle(LintelBrand.secondaryText)
                            .padding(Self.groupLabelInsets)
                            .accessibilityAddTraits(.isHeader)
                    } else {
                        Color.clear.frame(height: Self.untitledGroupGap).accessibilityHidden(true)
                    }
                    ForEach(section.items) { item in row(item) }
                }
            }
            .padding(.top, Self.titleBarInset)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
        .frame(width: (Self.width * min(textSize.scale, 1.15)).rounded())
        .frame(maxHeight: .infinity)
        .background(LintelBrand.sidebarBackground)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.downArrow) { move(by: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.sidebar")
    }

    /// The id the arrow keys select next, or `nil` at either end.
    static func neighbour(of selection: String, by step: Int, in sections: [SettingsSidebarModel.Section]) -> String? {
        let order = SettingsSidebarModel.focusOrder(sections)
        guard let index = order.firstIndex(of: selection) else { return order.first }
        let next = index + step
        return order.indices.contains(next) ? order[next] : nil
    }

    private func move(by step: Int) -> KeyPress.Result {
        guard let next = Self.neighbour(of: selection, by: step, in: sections) else { return .ignored }
        onSelect(next)
        return .handled
    }

    private func row(_ item: SettingsSidebarModel.Item) -> some View {
        let isSelected = item.id == selection
        return rowButton(
            title: item.title, symbol: item.symbolName, isSelected: isSelected, isActive: item.isActive,
            accessibilityLabel: item.accessibilityLabel, action: { onSelect(item.id) }
        ) {
            if !item.isActive {
                Text(String(localized: "settings.sidebar.off", defaultValue: "Off", comment: "Feature state"))
                    .font(textSize.font(.caption1))
                    .foregroundStyle(LintelBrand.secondaryText)
            } else if let level = item.attention {
                Circle()
                    .fill(level == .error ? LintelBrand.statusError : LintelBrand.statusAttention)
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.pane.\(item.id)")
    }

    private func rowButton(
        title: String, symbol: String, isSelected: Bool, isActive: Bool = true, accessibilityLabel: String? = nil,
        action: @escaping () -> Void,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(textSize.font(.body))
                    .foregroundStyle(
                        isSelected ? AnyShapeStyle(LintelBrand.accentText) : AnyShapeStyle(LintelBrand.secondaryText)
                    )
                    .frame(width: (16 * textSize.scale).rounded())
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .font(textSize.font(.body, weight: isSelected ? .semibold : nil))
                    .foregroundStyle(
                        isSelected
                            ? AnyShapeStyle(LintelBrand.accentText)
                            : isActive ? AnyShapeStyle(LintelBrand.ink) : AnyShapeStyle(LintelBrand.secondaryText)
                    )
                    .lineLimit(1)
                Spacer(minLength: 4)
                trailing()
            }
            .padding(Self.rowPadding)
            .frame(maxWidth: .infinity, minHeight: (Self.rowHeight * textSize.scale).rounded(), alignment: .leading)
            .background(
                isSelected ? LintelBrand.windowSelectionTint : Color.clear,
                in: RoundedRectangle(cornerRadius: Self.rowCornerRadius)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Self.rowInset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel ?? title))
        .accessibilityAddTraits(.isButton)
    }
}
