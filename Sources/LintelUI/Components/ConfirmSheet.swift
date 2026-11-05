import SwiftUI

/// A confirmation for Clear and Erase in a pane: a prompt, one line of detail, an optional explanation with a
/// checkbox, Cancel on the left and the filled red confirm verb on the right. Cancel is the default button
/// (Return and Esc both cancel), so a stray Return never deletes anything.
public struct ConfirmSheet: View {
    private let prompt: LocalizedStringResource
    private let detail: LocalizedStringResource
    private let confirmTitle: LocalizedStringResource
    private let option: DestructiveConfirmation.Option?
    private let onConfirm: (Bool) -> Void
    private let onCancel: () -> Void
    @State private var optionIsOn: Bool
    @Environment(\.lintelTextSize) private var textSize

    public init(
        prompt: LocalizedStringResource,
        detail: LocalizedStringResource,
        confirmTitle: LocalizedStringResource,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.init(
            prompt: prompt, detail: detail, confirmTitle: confirmTitle, option: nil, onConfirm: { _ in onConfirm() },
            onCancel: onCancel)
    }

    /// A sheet with an optional checkbox under the detail; `onConfirm` receives the checkbox's state (`false`
    /// without one).
    public init(
        prompt: LocalizedStringResource,
        detail: LocalizedStringResource,
        confirmTitle: LocalizedStringResource,
        option: DestructiveConfirmation.Option?,
        onConfirm: @escaping (Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.prompt = prompt
        self.detail = detail
        self.confirmTitle = confirmTitle
        self.option = option
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _optionIsOn = State(initialValue: option?.isOnByDefault ?? false)
    }

    /// The checkbox's state when the sheet opens.
    var initialOptionState: Bool { option?.isOnByDefault ?? false }

    func confirmTapped() { onConfirm(option == nil ? false : optionIsOn) }
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
            if let option {
                if let explanation = option.explanation {
                    Text(explanation)
                        .font(textSize.font(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: $optionIsOn) {
                    Text(option.title)
                        .font(textSize.font(.body))
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Button(action: cancelTapped) {
                    Text("Cancel", comment: "Confirmation sheet button that keeps everything as it is")
                }
                .buttonStyle(LintelSecondaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                Spacer()
                Button(role: .destructive, action: confirmTapped) {
                    Text(confirmTitle)
                }
                .buttonStyle(LintelDestructiveProminentButtonStyle())
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
    /// A checkbox in the main window's sheet, with an optional sentence above it. The old window's dialog has
    /// no checkbox, so there the confirm closure always receives `false`.
    public struct Option: Sendable {
        public let explanation: LocalizedStringResource?
        public let title: LocalizedStringResource
        public let isOnByDefault: Bool

        public init(
            explanation: LocalizedStringResource? = nil, title: LocalizedStringResource, isOnByDefault: Bool = false
        ) {
            self.explanation = explanation
            self.title = title
            self.isOnByDefault = isOnByDefault
        }
    }

    public let prompt: LocalizedStringResource
    public let detail: LocalizedStringResource
    /// The main window's sheet shows this instead of `detail` when set. The old window keeps `detail` word for word
    /// (until step 6.3b removes the old window).
    public let mainWindowDetail: LocalizedStringResource?
    public let confirmTitle: LocalizedStringResource
    /// The old window's dialog shows its title only where it always did.
    public let legacyTitleVisible: Bool
    public let option: Option?

    public init(
        prompt: LocalizedStringResource,
        detail: LocalizedStringResource,
        confirmTitle: LocalizedStringResource,
        legacyTitleVisible: Bool = false,
        option: Option? = nil,
        mainWindowDetail: LocalizedStringResource? = nil
    ) {
        self.prompt = prompt
        self.detail = detail
        self.mainWindowDetail = mainWindowDetail
        self.confirmTitle = confirmTitle
        self.legacyTitleVisible = legacyTitleVisible
        self.option = option
    }

    /// The same words with `option` (or without one for `nil`).
    public func with(option: Option?) -> DestructiveConfirmation {
        DestructiveConfirmation(
            prompt: prompt, detail: detail, confirmTitle: confirmTitle, legacyTitleVisible: legacyTitleVisible,
            option: option, mainWindowDetail: mainWindowDetail)
    }

    /// The checkbox shown for a host: only the main window's sheet has one.
    public func option(in hostStyle: SettingsHostStyle) -> Option? {
        hostStyle == .mainWindow ? option : nil
    }
}

extension DestructiveConfirmation.Option {
    /// Clear and Erase in Meetings and Dictation (owner decision L1-39): copies edited or commented on in Notes
    /// are kept unless the user ticks the box. Shown only in DEBUG builds until Notes ships (spec
    /// `2026-11-04-notes-workspace`, step 7.1 removes the guards at the call sites).
    public static let keptNotesCopies = DestructiveConfirmation.Option(
        explanation: LocalizedStringResource(
            "Copies you edited or commented on in Notes stay until you delete them there.",
            comment: "Confirmation sheet: Clear or Erase in Meetings and Dictation keeps the edited copies in Notes"),
        title: LocalizedStringResource(
            "Also delete kept copies",
            comment: "Confirmation sheet checkbox: also delete the copies kept in Notes"))
}

private struct DestructiveConfirmationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let confirmation: DestructiveConfirmation
    let onConfirm: (Bool) -> Void
    @Environment(\.settingsHostStyle) private var hostStyle

    func body(content: Content) -> some View {
        switch hostStyle {
        case .mainWindow:
            content.sheet(isPresented: $isPresented) {
                ConfirmSheet(
                    prompt: confirmation.prompt, detail: confirmation.mainWindowDetail ?? confirmation.detail,
                    confirmTitle: confirmation.confirmTitle,
                    option: confirmation.option(in: .mainWindow),
                    onConfirm: confirmThenClose(isPresented: $isPresented, onConfirm),
                    onCancel: { isPresented = false })
            }
        case .legacyWindow:
            content.confirmationDialog(
                Text(confirmation.prompt), isPresented: $isPresented,
                titleVisibility: confirmation.legacyTitleVisible ? .visible : .automatic
            ) {
                Button(role: .destructive) {
                    onConfirm(false)
                } label: {
                    Text(confirmation.confirmTitle)
                }
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
            DestructiveConfirmationModifier(
                isPresented: isPresented, confirmation: confirmation, onConfirm: { _ in onConfirm() }))
    }

    /// The same, for a confirmation with an `option`: `onConfirm` receives the checkbox's state, always `false`
    /// in the old window (its dialog has no checkbox).
    public func destructiveConfirmation(
        isPresented: Binding<Bool>, _ confirmation: DestructiveConfirmation,
        onConfirmWithOption onConfirm: @escaping (Bool) -> Void
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
                onConfirm: confirmThenClose(isPresented: isPresented, onConfirm),
                onCancel: { isPresented.wrappedValue = false }
            )
        }
    }
}

/// Runs the confirmed action first and closes the sheet afterwards: closing goes through the binding's setter,
/// which may clear the very state the action reads (Meetings' "Delete Older Meetings" cancels the pending
/// retention when its sheet closes).
func confirmThenClose(isPresented: Binding<Bool>, _ onConfirm: @escaping () -> Void) -> () -> Void {
    {
        onConfirm()
        isPresented.wrappedValue = false
    }
}

/// `confirmThenClose` for a confirm closure that receives the checkbox's state.
func confirmThenClose(isPresented: Binding<Bool>, _ onConfirm: @escaping (Bool) -> Void) -> (Bool) -> Void {
    { option in
        onConfirm(option)
        isPresented.wrappedValue = false
    }
}
