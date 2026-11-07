import SwiftUI

/// The motion of the Notes section (owner feedback: everything jumped). Short ease curves of 0.15 to 0.25 s for the
/// few changes the eye should follow: a tab opening, closing or switching, the inspector, the explorer's
/// selection, strips and feedback, the editor and the reader swapping, the pen. The policy is a pure function so
/// it is tested without a window: **Reduce Motion** (System Settings → Accessibility → Display) and the QA
/// snapshot paths get no animation and no transition at all, so a change is instant and a render is deterministic.
enum NotesMotion {
    enum Kind: CaseIterable, Sendable {
        /// The explorer's selection highlight and other small colour changes.
        case selection
        /// The pen button lighting up.
        case pen
        /// A tab opening, closing or being selected, and the document under it changing.
        case tab
        /// A strip or a feedback word appearing or leaving.
        case strip
        /// The editor and the read-only view swapping places.
        case editorSwitch
        /// The inspector showing or hiding.
        case inspector
    }

    /// Seconds. Every value is within 0.15 to 0.25.
    static func duration(_ kind: Kind) -> Double {
        switch kind {
        case .selection, .pen: 0.15
        case .tab, .strip, .editorSwitch: 0.2
        case .inspector: 0.25
        }
    }

    /// `nil` (no animation, the change is immediate) under Reduce Motion or when animations are switched off.
    static func animation(_ kind: Kind, reduceMotion: Bool, disabled: Bool = false) -> Animation? {
        guard !reduceMotion, !disabled else { return nil }
        return .easeInOut(duration: duration(kind))
    }

    /// Whether anything may move at all.
    static func allowsMotion(reduceMotion: Bool, disabled: Bool = false) -> Bool { !reduceMotion && !disabled }
}

private struct NotesAnimationsDisabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// QA runs (`--qa-notes`, so `--qa-snapshot` too) switch every Notes animation off.
    var notesAnimationsDisabled: Bool {
        get { self[NotesAnimationsDisabledKey.self] }
        set { self[NotesAnimationsDisabledKey.self] = newValue }
    }
}

private struct NotesAnimationModifier<Value: Equatable>: ViewModifier {
    let kind: NotesMotion.Kind
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.notesAnimationsDisabled) private var disabled

    func body(content: Content) -> some View {
        content.animation(NotesMotion.animation(kind, reduceMotion: reduceMotion, disabled: disabled), value: value)
    }
}

private struct NotesTransitionModifier: ViewModifier {
    let kind: NotesMotion.Kind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.notesAnimationsDisabled) private var disabled

    func body(content: Content) -> some View {
        content.transition(
            NotesMotion.allowsMotion(reduceMotion: reduceMotion, disabled: disabled) ? .opacity : .identity)
    }
}

extension View {
    /// Animates this view's changes when `value` changes, with the Notes curve of `kind`, or not at all.
    func notesAnimation<Value: Equatable>(_ kind: NotesMotion.Kind, value: Value) -> some View {
        modifier(NotesAnimationModifier(kind: kind, value: value))
    }

    /// A fade for a view that is inserted or removed, or none under Reduce Motion.
    func notesFade(_ kind: NotesMotion.Kind) -> some View {
        modifier(NotesTransitionModifier(kind: kind))
    }
}
