import LintelUI
import SwiftUI

/// The new-comment popover under the selection (prototype `.pop`): "New comment", the field, Cancel and
/// "Comment ⌘↩". Return in the field is a new line; ⌘↩ sends, Escape cancels.
struct CommentPopover: View {
    /// Writes the comment; `true` when it was written (the popover then closes), `false` keeps the text.
    let onSubmit: (String) async -> Bool
    let onCancel: () -> Void
    @State private var text = ""
    @State private var isSending = false
    @FocusState private var focused: Bool
    @Environment(\.lintelTextSize) private var textSize

    /// The prototype's `width:20em` of the 12.5 pt root.
    static func width(_ size: TextSize) -> CGFloat { 20 * 12.5 * size.scale }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").accessibilityHidden(true)
                Text("New comment", comment: "Comment popover: title")
            }
            .font(textSize.font(.callout, weight: .semibold))
            .foregroundStyle(LintelBrand.ink)
            .accessibilityAddTraits(.isHeader)
            TextField(
                text: $text, axis: .vertical,
                label: { Text("Comment", comment: "Accessibility label of the comment field") }
            )
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .font(textSize.font(.callout))
            .foregroundStyle(LintelBrand.ink)
            .focused($focused)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(LintelBrand.accent))
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button(action: onCancel) {
                    Text("Cancel", comment: "Comment popover: closes without writing")
                        .font(textSize.font(.callout))
                        .foregroundStyle(LintelBrand.accentText)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Button {
                    send()
                } label: {
                    HStack(spacing: 6) {
                        Text("Comment", comment: "Comment popover: writes the comment")
                        Text(verbatim: "⌘↩").accessibilityHidden(true)
                    }
                }
                .buttonStyle(LintelPrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
            }
        }
        .padding(10)
        .frame(width: Self.width(textSize))
        .background(LintelBrand.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(LintelBrand.hairline))
        .shadow(color: LintelBrand.ink.opacity(0.18), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("New comment", comment: "Comment popover: title"))
        .onAppear { focused = true }
    }

    private func send() {
        guard canSend else { return }
        isSending = true
        Task {
            let written = await onSubmit(text)
            isSending = false
            if !written { focused = true }
        }
    }
}
