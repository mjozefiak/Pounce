import LintelUI
import SwiftUI

/// The form that adds or edits a term (prototype `.inl` with `.fm` fields): "Write as", "When I hear" with tokens,
/// the example, the warning for a short variant, the buttons. Problems appear after Add or Save, next to the
/// field, and the focus goes to that field.
struct VocabularyFormView: View {
    @Bindable var model: VocabularyPanelModel
    /// The form is the list's first row (a new term, or the first term being edited): rounded top corners and no
    /// hairline above it (prototype `.inl:first-child`).
    var isFirst = true

    @Environment(\.lintelTextSize) private var textSize
    @State private var termFocused = false
    @State private var aliasFocused = false

    private var form: VocabularyPanelModel.Editor { model.editor ?? .init(target: .adding) }
    private var fieldSize: CGFloat { NSFont.preferredFont(forTextStyle: .body).pointSize * textSize.scale }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            termField
            aliasField
            if !model.unconfirmedShortAliases.isEmpty { shortAliasBox }
            // The prototype shows the example only for a form with nothing to fix or confirm.
            if let example = model.example, showsExample { exampleBox(example) }
            if form.saveFailed {
                VocabularyStrip(
                    symbol: "exclamationmark.triangle", tint: LintelBrand.statusError.opacity(0.11),
                    text: Text(VocabularyText.saveFailed()), iconTint: LintelBrand.statusError)
            }
            buttons
                .padding(.top, 6)
        }
        // The prototype's `.inl`: the fill reaches the card's edges, with rounded top corners as the first row.
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background {
            Group {
                if isFirst {
                    UnevenRoundedRectangle(topLeadingRadius: 9, topTrailingRadius: 9).fill(LintelBrand.fill)
                } else {
                    // The row above already ends with the list's hairline.
                    Rectangle().fill(LintelBrand.fill)
                }
            }
            .padding(.horizontal, -VocabularyListView.cardInset)
        }
        .onExitCommand { model.cancelEditing() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text("Term form", comment: "VoiceOver: the form that adds or edits a vocabulary term"))
    }

    // MARK: Fields

    private var termField: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Write as", comment: "Vocabulary form: label of the term field")
                .font(textSize.font(.body, weight: .semibold))
            FormTextField(
                text: Binding(get: { form.term }, set: { model.setTerm($0) }),
                placeholder: String(
                    localized: "e.g. AuthService", comment: "Vocabulary form: placeholder of the term field"),
                accessibilityLabel: String(
                    localized: "Write as", comment: "Vocabulary form: label of the term field"),
                size: fieldSize, wantsFocus: form.focus == .term, focusTick: form.focusTick,
                onReturn: { model.returnInTerm() }, onEscape: { model.cancelEditing() },
                onFocusChange: { termFocused = $0 }
            )
            .modifier(FieldFrame(focused: termFocused, failed: model.termMessage != nil))
            if let message = model.termMessage {
                VocabularyFieldMessage(text: message) {
                    if model.duplicateRowID != nil {
                        Button {
                            model.showDuplicate()
                        } label: {
                            Text("Show", comment: "Vocabulary form: link that points at the existing term")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(LintelBrand.accentText)
                    }
                }
            }
        }
    }

    private var aliasField: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("When I hear", comment: "Vocabulary form: label of the field with the spoken variants")
                .font(textSize.font(.body, weight: .semibold))
            let shortKeys = Set(model.unconfirmedShortAliases.map(VocabularyRules.key))
            WrappingLayout(horizontalSpacing: 5, verticalSpacing: 4, lastFillsLine: true) {
                ForEach(Array(form.aliases.enumerated()), id: \.offset) { offset, alias in
                    VocabularyToken(
                        alias: alias, position: offset + 1, total: form.aliases.count,
                        state: tokenState(alias, shortKeys: shortKeys), remove: { model.removeAlias(at: offset) })
                }
                FormTextField(
                    text: Binding(get: { form.pending }, set: { model.setPending($0) }),
                    placeholder: form.aliases.isEmpty
                        ? String(
                            localized: "type and press Return",
                            comment: "Vocabulary form: placeholder of the variants field") : "",
                    accessibilityLabel: String(
                        localized: "When I hear",
                        comment: "Vocabulary form: label of the field with the spoken variants"),
                    size: fieldSize, wantsFocus: form.focus == .aliases, focusTick: form.focusTick, idealWidth: 120,
                    onReturn: { model.returnInAliases() }, onEscape: { model.cancelEditing() },
                    onBackspaceWhenEmpty: { model.removeLastAlias() }, onFocusChange: { aliasFocused = $0 }
                )
                .frame(minWidth: 120)
            }
            .modifier(FieldFrame(focused: aliasFocused, failed: model.aliasMessage != nil))
            if let message = model.aliasMessage {
                VocabularyFieldMessage(text: message) { EmptyView() }
            } else {
                Text(hint)
                    .font(textSize.font(.callout))
                    .foregroundStyle(LintelBrand.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var showsExample: Bool {
        model.termMessage == nil && model.aliasMessage == nil && model.unconfirmedShortAliases.isEmpty
            && !form.saveFailed
    }

    private var hint: String {
        // Only for a term that can be saved (prototype `err-dupterm` keeps the usual hint).
        if model.effectiveAliases.isEmpty, !VocabularyRules.tidy(form.term).isEmpty, model.termMessage == nil {
            return VocabularyText.withoutVariantsHint(VocabularyRules.tidy(form.term))
        }
        return String(
            localized: "Add every way it is said or misheard, inflected forms too.",
            comment: "Vocabulary form: hint under the variants field")
    }

    private func tokenState(_ alias: String, shortKeys: Set<String>) -> VocabularyToken.State {
        if alias == form.badAlias { return .failed }
        return shortKeys.contains(VocabularyRules.key(alias)) ? .warning : .normal
    }

    // MARK: Short variant (D8)

    private var shortAliasBox: some View {
        let aliases = model.unconfirmedShortAliases
        let term = VocabularyRules.tidy(form.term)
        let warning = VocabularyText.shortAliasWarning(aliases, term: term.isEmpty ? "…" : term)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(LintelBrand.statusAttention)
                    .accessibilityHidden(true)
                Text("Risk of wrong replacements", comment: "Vocabulary form: title of the short-variant warning")
                    .font(textSize.font(.body, weight: .semibold))
            }
            Text(warning)
                .font(textSize.font(.body))
                .fixedSize(horizontal: false, vertical: true)
            Toggle(
                isOn: Binding(
                    get: { model.shortAliasesAreConfirmed }, set: { model.setShortAliasesConfirmed($0) })
            ) {
                Text(VocabularyText.shortAliasConfirmation(aliases)).font(textSize.font(.body))
            }
            .toggleStyle(.checkbox)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LintelBrand.statusAttention.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .onAppear { model.announce(warning) }
    }

    // MARK: Example (D5)

    private func exampleBox(_ example: (heard: String, inserted: String, term: String, phrase: String)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            exampleLine(
                Text("Heard", comment: "Vocabulary form: label of the example sentence as spoken"),
                Text(struck(example.heard, phrase: example.phrase)))
            exampleLine(
                Text("Inserted", comment: "Vocabulary form: label of the example sentence after the replacement"),
                Text(marked(example.inserted, term: example.term)))
        }
        .font(textSize.font(.callout))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LintelBrand.fill, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text("Replacement example", comment: "VoiceOver: the example of the replacement in the vocabulary form"))
    }

    private func exampleLine(_ label: Text, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Prototype `.pv .k`: 0.88 of the example's size, semibold, secondary, 6.5 em wide.
            label
                .font(textSize.font(.subheadline, weight: .semibold))
                .foregroundStyle(LintelBrand.secondaryText)
                .frame(width: 72 * textSize.scale, alignment: .leading)
            text
        }
    }

    private func struck(_ text: String, phrase: String) -> AttributedString {
        var result = AttributedString(text)
        if let found = text.range(of: phrase), let range = Range(found, in: result) {
            // Prototype `s.was`: struck through and in the secondary colour.
            result[range].strikethroughStyle = .single
            result[range].foregroundColor = LintelBrand.secondaryText
        }
        return result
    }

    private func marked(_ text: String, term: String) -> AttributedString {
        var result = AttributedString(text)
        if let found = text.range(of: term), let range = Range(found, in: result) {
            result[range].backgroundColor = LintelBrand.windowSelectionTint
            result[range].foregroundColor = LintelBrand.accentText
            result[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                model.cancelEditing()
            } label: {
                Text("Cancel", comment: "Button that closes a form without saving")
            }
            .buttonStyle(LintelSecondaryButtonStyle())
            Button {
                model.submit()
            } label: {
                Text(primaryTitle)
            }
            .buttonStyle(LintelPrimaryButtonStyle())
            .disabled(!model.canSubmit)
        }
    }

    private var primaryTitle: LocalizedStringResource {
        if form.saveFailed {
            return LocalizedStringResource("Try Again", comment: "Button that repeats an action that failed")
        }
        switch form.target {
        case .adding: return LocalizedStringResource("Add", comment: "Button that adds the entry of a form")
        case .editing: return LocalizedStringResource("Save", comment: "Button that saves the entry of a form")
        }
    }
}

/// The border of a field: a hairline, the accent with a tint ring while it has the keyboard, the error colour
/// with a ring after a problem (prototype `.inp`, `.foc`, `.bad`).
private struct FieldFrame: ViewModifier {
    let focused: Bool
    let failed: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(LintelBrand.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        failed ? LintelBrand.statusError : focused ? LintelBrand.accent : LintelBrand.hairline,
                        lineWidth: failed || focused ? 1.5 : 1)
            }
            .background {
                if failed || focused {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(failed ? LintelBrand.statusError.opacity(0.15) : LintelBrand.windowSelectionTint)
                        .padding(-2)
                }
            }
    }
}

/// An error under a field: the warning icon and the text in the error colour, never colour alone.
struct VocabularyFieldMessage<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: Trailing

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            trailing
        }
        .font(textSize.font(.callout))
        .foregroundStyle(LintelBrand.statusError)
        .accessibilityElement(children: .combine)
    }
}

/// A spoken variant in the form: a pill with a remove button (D4). One element for VoiceOver.
struct VocabularyToken: View {
    enum State { case normal, warning, failed }

    let alias: String
    let position: Int
    let total: Int
    let state: State
    let remove: () -> Void

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Text(alias)
                Image(systemName: "xmark")
                    .font(textSize.font(.caption1, weight: .semibold))
                    .foregroundStyle(LintelBrand.secondaryText)
            }
            .font(textSize.font(.callout))
            .foregroundStyle(state == .failed ? LintelBrand.statusError : LintelBrand.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(LintelBrand.fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if state != .normal {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            state == .failed ? LintelBrand.statusError : LintelBrand.statusAttention, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(VocabularyText.tokenLabel(alias, position: position, of: total))
        .accessibilityHint(
            Text("Press to remove.", comment: "VoiceOver hint on a spoken variant in the vocabulary form"))
    }
}
