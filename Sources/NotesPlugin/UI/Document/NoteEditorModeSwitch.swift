import LintelKit
import LintelUI
import SwiftUI

/// The path bar's two-way switch between Formatted and Raw (⌥⌘R), drawn like the layer switch.
struct NoteEditorModeSwitch: View {
    let model: NotesWorkspaceModel
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        HStack(spacing: 0) {
            ForEach(NoteEditorMode.allCases, id: \.self) { mode in
                let isOn = model.editorMode == mode
                Button {
                    model.setEditorMode(mode)
                } label: {
                    label(mode)
                        .font(textSize.font(.footnote, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? LintelBrand.ink : LintelBrand.secondaryText)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8 * textSize.scale)
                        .padding(.vertical, 2 * textSize.scale)
                        .background(isOn ? LintelBrand.card : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .help(Text("Switch with ⌥⌘R", comment: "Tooltip of the Formatted / Raw switch"))
            }
        }
        .padding(2)
        .background(LintelBrand.fill, in: RoundedRectangle(cornerRadius: 7))
        .notesAnimation(.selection, value: model.editorMode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Editor view", comment: "Accessibility label of the Formatted / Raw switch"))
        .padding(.trailing, 6)
    }

    private func label(_ mode: NoteEditorMode) -> Text {
        switch mode {
        case .formatted: Text("Formatted", comment: "Path bar: the editor shows the Markdown styled")
        case .raw: Text("Raw", comment: "Path bar: the editor shows the plain Markdown source")
        }
    }
}
