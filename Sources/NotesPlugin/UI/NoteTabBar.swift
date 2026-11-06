import LintelKit
import LintelUI
import SwiftUI

/// The tab bar (prototype `.tbs`): one tab per open note with its icon, title, a busy mark and a close button.
/// The selected tab has the window's background and the accent line under it.
struct NoteTabBar: View {
    let model: NotesWorkspaceModel
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.tabs.tabs) { tab in
                        NoteTabView(model: model, tab: tab, isSelected: model.currentID == tab.id)
                    }
                }
            }
            .frame(height: 33.75 * textSize.scale)
            .background(LintelBrand.sidebarBackground)
            LintelDivider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Open notes", comment: "Accessibility label of the tab bar"))
    }
}

struct NoteTabView: View {
    let model: NotesWorkspaceModel
    let tab: NoteTab
    let isSelected: Bool
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        HStack(spacing: 0) {
            Button {
                model.select(tab.id)
            } label: {
                HStack(spacing: 7 * textSize.scale) {
                    Image(systemName: tab.kind.symbolName)
                        .accessibilityHidden(true)
                    Text(verbatim: tab.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if tab.isBusy {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(textSize.font(.caption1))
                            .foregroundStyle(LintelBrand.accentText)
                            .accessibilityHidden(true)
                    }
                }
                .font(textSize.font(.callout))
                .foregroundStyle(isSelected ? LintelBrand.ink : LintelBrand.secondaryText)
                .padding(.leading, 12 * textSize.scale)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                Text(
                    verbatim: tab.isBusy
                        ? "\(tab.title), \(String(localized: "Working", comment: "Accessibility: a note is being worked on"))"
                        : tab.title)
            )
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            Button {
                model.close(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(textSize.font(.caption2, weight: .semibold))
                    .foregroundStyle(LintelBrand.secondaryText)
                    .opacity(0.8)
                    .frame(width: 24 * textSize.scale, height: 24 * textSize.scale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4 * textSize.scale)
            .accessibilityLabel(Text("Close tab", comment: "Accessibility label of a tab's close button"))
        }
        .frame(minWidth: 96 * textSize.scale, maxWidth: 15 * 12.5 * textSize.scale)
        .frame(maxHeight: .infinity)
        .background(isSelected ? LintelBrand.windowBackground : Color.clear)
        .overlay(alignment: .bottom) {
            if isSelected { LintelBrand.accent.frame(height: 2) }
        }
        .overlay(alignment: .trailing) { LintelDivider(axis: .vertical) }
    }
}

/// The path bar (prototype `.crb`): where the note sits in the explorer, in the monospaced face.
struct NotePathBar: View {
    let model: NotesWorkspaceModel
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let path = model.pathComponents {
                    Text(verbatim: path.joined(separator: " / "))
                        .font(textSize.font(.footnote).monospaced())
                        .foregroundStyle(LintelBrand.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(
                            Text(verbatim: path.joined(separator: ", ")))
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 16 * textSize.scale)
            .padding(.trailing, 12 * textSize.scale)
            .frame(height: 32.5 * textSize.scale)
            LintelDivider()
        }
        .accessibilityElement(children: .contain)
    }
}

/// The status bar (prototype `.sbar`): what is true of the whole section, in words.
struct NotesStatusBar: View {
    let model: NotesWorkspaceModel
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(spacing: 0) {
            LintelDivider()
            HStack(spacing: 14) {
                Label {
                    Text("Encrypted on this Mac", comment: "Notes status bar: where the notes are stored")
                } icon: {
                    Image(systemName: "lock")
                }
                Spacer(minLength: 0)
                Text(verbatim: model.statusSummary)
            }
            .font(textSize.font(.footnote))
            .foregroundStyle(LintelBrand.secondaryText)
            .padding(.horizontal, 12 * textSize.scale)
            .frame(height: 26 * textSize.scale)
            .background(LintelBrand.sidebarBackground)
        }
        .accessibilityElement(children: .combine)
    }
}
