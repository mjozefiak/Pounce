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

    func confirmTapped() { onConfirm() }
    func cancelTapped() { onCancel() }

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
                Button(role: .destructive, action: confirmTapped) {
                    Text(confirmTitle)
                }
                Button(action: cancelTapped) {
                    Text("Cancel", comment: "Confirmation sheet button that keeps everything as it is")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        // A view takes one keyboard shortcut, so Esc goes through a second, invisible Cancel button; the exit
        // command covers a focused control that swallows the shortcut.
        .background {
            Button(action: cancelTapped) { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onExitCommand(perform: cancelTapped)
        .padding(20)
        .frame(width: 380)
    }
}

/// The words of one destructive action: a question, one sentence of consequence, and a verb for the confirm
/// button (never "OK"). Shown as a `ConfirmSheet` in the main window and as the system dialog in the old window.
public struct DestructiveConfirmation: Sendable {
    public let prompt: LocalizedStringResource
    public let detail: LocalizedStringResource
    public let confirmTitle: LocalizedStringResource
    /// The old window's dialog shows its title only where it always did.
    public let legacyTitleVisible: Bool

    public init(
        prompt: LocalizedStringResource,
        detail: LocalizedStringResource,
        confirmTitle: LocalizedStringResource,
        legacyTitleVisible: Bool = false
    ) {
        self.prompt = prompt
        self.detail = detail
        self.confirmTitle = confirmTitle
        self.legacyTitleVisible = legacyTitleVisible
    }
}

private struct DestructiveConfirmationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let confirmation: DestructiveConfirmation
    let onConfirm: () -> Void
    @Environment(\.settingsHostStyle) private var hostStyle

    func body(content: Content) -> some View {
        switch hostStyle {
        case .mainWindow:
            content.confirmSheet(
                isPresented: $isPresented, prompt: confirmation.prompt, detail: confirmation.detail,
                confirmTitle: confirmation.confirmTitle, onConfirm: onConfirm)
        case .legacyWindow:
            content.confirmationDialog(
                Text(confirmation.prompt), isPresented: $isPresented,
                titleVisibility: confirmation.legacyTitleVisible ? .visible : .automatic
            ) {
                Button(role: .destructive, action: onConfirm) { Text(confirmation.confirmTitle) }
            } message: {
                Text(confirmation.detail)
            }
        }
    }
}

extension View {
    /// Asks before a destructive action: a `ConfirmSheet` (Cancel is the default button) in the main window, the
    /// old window's confirmation dialog under `.legacyWindow`, so release behaviour does not change.
    public func destructiveConfirmation(
        isPresented: Binding<Bool>, _ confirmation: DestructiveConfirmation, onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(
            DestructiveConfirmationModifier(isPresented: isPresented, confirmation: confirmation, onConfirm: onConfirm))
    }

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
