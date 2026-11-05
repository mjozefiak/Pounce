import LintelKit
import LintelUI
import SwiftUI

/// The Settings sidebar of the main window: a plain list (no sidebar material, no glass in Settings) in the five
/// groups of `SettingsSidebarModel`. Disabled plugins stay in place, dimmed and spoken as "Off"; a pane that needs
/// attention carries a dot whose meaning is in the row's accessibility label.
struct SettingsSidebar: View {
    let sections: [SettingsSidebarModel.Section]
    let selection: String
    let onSelect: (String) -> Void
    /// Returns to the Workspace; `nil` while no workspace section exists, which hides the row.
    let onBack: (() -> Void)?

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(spacing: 0) {
            if let onBack {
                Button(action: onBack) {
                    Label(
                        String(localized: "Back to Workspace", comment: "Settings sidebar: returns to the workspace"),
                        systemImage: "chevron.left"
                    )
                    .font(textSize.font(.body))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LintelBrand.accentText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .accessibilityIdentifier("settings.back")
            }
            List(
                selection: Binding(get: { selection }, set: { if let id = $0 { onSelect(id) } })
            ) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in row(item) }
                    } header: {
                        Text(section.title)
                            .font(textSize.font(.caption1, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 220)
    }

    private func row(_ item: SettingsSidebarModel.Item) -> some View {
        HStack(spacing: 6) {
            Label(item.title, systemImage: item.symbolName)
                .font(textSize.font(.body))
                .opacity(item.isActive ? 1 : 0.5)
            Spacer(minLength: 4)
            if !item.isActive {
                Text(String(localized: "Off", comment: "Feature state"))
                    .font(textSize.font(.caption1))
                    .foregroundStyle(.secondary)
            }
            if let level = item.attention {
                Circle()
                    .fill(level == .error ? LintelBrand.statusError : LintelBrand.statusAttention)
                    .frame(width: 8, height: 8)
            }
        }
        .tag(item.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: item.accessibilityLabel))
        .accessibilityIdentifier("settings.pane.\(item.id)")
    }
}
