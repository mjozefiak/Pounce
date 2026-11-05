import SwiftUI

/// A confirmation for Clear and Erase in a pane: a prompt, one line of detail, Cancel and the confirm verb.
/// Cancel is the default button (Return and Esc both cancel), so a stray Return never deletes anything.
public struct ConfirmSheet: View {
    private let prompt: LocalizedStringResource
    private let detail: LocalizedStringResource
    private let confirmTitle: LocalizedStringResource
    private let onConfirm: () -> Void
    private let onCancel: () -> Void
    @Environment(\.lintelTextSize) private var textSize

    public init(
        prompt: LocalizedStringResource,
        detail: LocalizedStringResource,
        confirmTitle: LocalizedStringResource,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.prompt = prompt
        self.detail = detail
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt)
                .font(textSize.font(.headline))
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(textSize.font(.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(role: .destructive, action: onConfirm) {
                    Text(confirmTitle)
                }
                Button(action: onCancel) {
                    Text("Cancel", comment: "Confirmation sheet button that keeps everything as it is")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        // A view takes one keyboard shortcut, so Esc goes through a second, invisible Cancel button; the exit
        // command covers a focused control that swallows the shortcut.
        .background {
            Button(action: onCancel) { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onExitCommand(perform: onCancel)
        .padding(20)
        .frame(width: 380)
    }
}

extension View {
    /// Presents a `ConfirmSheet`. Confirming runs `onConfirm` and closes the sheet; Cancel only closes it.
    public func confirmSheet(
        isPresented: Binding<Bool>,
        prompt: LocalizedStringResource,
        detail: LocalizedStringResource,
        confirmTitle: LocalizedStringResource,
        onConfirm: @escaping () -> Void
    ) -> some View {
        sheet(isPresented: isPresented) {
            ConfirmSheet(
                prompt: prompt,
                detail: detail,
                confirmTitle: confirmTitle,
                onConfirm: {
                    isPresented.wrappedValue = false
                    onConfirm()
                },
                onCancel: { isPresented.wrappedValue = false }
            )
        }
    }
}
