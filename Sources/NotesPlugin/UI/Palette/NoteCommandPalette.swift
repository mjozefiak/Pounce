import LintelKit
import LintelUI
import SwiftUI

/// The command palette (prototype `lib-palette`, `.pal`): a card over the top of the document with one search
/// field and a list of notes to go to and commands to run. Up and Down move, Return runs, Esc or a click outside
/// closes it. Everything is spoken: each line reads its title and its detail.
struct NoteCommandPalette: View {
    let model: NotesWorkspaceModel
    @Environment(\.lintelTextSize) private var textSize
    @FocusState private var focused: Bool

    private var query: Binding<String> {
        Binding(get: { model.palette?.query ?? "" }, set: { model.setPaletteQuery($0) })
    }

    var body: some View {
        let items = model.paletteItems
        let selection = model.palette?.selection ?? 0
        ZStack(alignment: .top) {
            // A click outside the card closes it.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.hidePalette() }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").accessibilityHidden(true)
                    TextField(
                        text: query,
                        prompt: Text(
                            "Go to a note or run a command", comment: "Command palette: placeholder of the field")
                    ) {
                        Text("Go to a note or run a command", comment: "Accessibility label of the palette's field")
                    }
                    .textFieldStyle(.plain)
                    .foregroundStyle(LintelBrand.ink)
                    .focused($focused)
                    .onSubmit { model.runPalette() }
                    .onKeyPress(.upArrow) {
                        model.movePaletteSelection(by: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        model.movePaletteSelection(by: 1)
                        return .handled
                    }
                    .onExitCommand { model.hidePalette() }
                }
                .font(textSize.font(.body))
                .foregroundStyle(LintelBrand.secondaryText)
                .padding(.horizontal, 14 * textSize.scale)
                .padding(.vertical, 10 * textSize.scale)
                LintelDivider()
                if items.isEmpty {
                    Text("No matches", comment: "Command palette: nothing fits what was typed")
                        .font(textSize.font(.callout))
                        .foregroundStyle(LintelBrand.secondaryText)
                        .padding(.horizontal, 14 * textSize.scale)
                        .padding(.vertical, 8 * textSize.scale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                PaletteRow(model: model, item: item, isSelected: index == selection)
                            }
                        }
                    }
                    .frame(maxHeight: 320 * textSize.scale)
                }
            }
            .frame(width: min(30 * 13 * textSize.scale, 520 * textSize.scale))
            .background(LintelBrand.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(LintelBrand.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: LintelBrand.ink.opacity(0.2), radius: 25, y: 10)
            .padding(.top, 65 * textSize.scale)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Command palette", comment: "Accessibility label of the command palette"))
            .accessibilityAddTraits(.isModal)
        }
        .onAppear { focused = true }
    }
}

/// One line (prototype `.pr`): the title, the detail in grey; the selected line has the tint and an accent title.
private struct PaletteRow: View {
    let model: NotesWorkspaceModel
    let item: PaletteItem
    let isSelected: Bool
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        Button {
            model.runPalette(item)
        } label: {
            HStack {
                Text(verbatim: item.title)
                    .font(textSize.font(.callout, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? LintelBrand.accentText : LintelBrand.ink)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(verbatim: item.detail)
                    .font(textSize.font(.callout))
                    .foregroundStyle(LintelBrand.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14 * textSize.scale)
            .padding(.vertical, 7 * textSize.scale)
            .background(isSelected ? LintelBrand.windowSelectionTint : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: item.detail.isEmpty ? item.title : "\(item.title), \(item.detail)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// "Hide content" (prototype `.blur`): the text of a hidden area is blurred, cannot be selected or read by
/// VoiceOver, and ignores the pointer.
struct HiddenContent: ViewModifier {
    let isHidden: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: isHidden ? 6 : 0)
            .allowsHitTesting(!isHidden)
            .accessibilityHidden(isHidden)
    }
}

extension View {
    func hiddenContent(_ isHidden: Bool) -> some View { modifier(HiddenContent(isHidden: isHidden)) }
}
