import SwiftUI

/// The measurements of the welcome screen's single column (prototype `shell-welcome-*`): a 600 pt window of
/// 420 pt, content inset 40 pt on the sides, the footer 24 x 12 pt below a hairline.
public nonisolated enum WelcomeLayout {
    public static let width: CGFloat = 600
    /// The prototype's 420 pt window less the title bar, which SwiftUI keeps as the top safe area.
    public static let minHeight: CGFloat = 388
    public static let contentInset: CGFloat = 40
    public static let markSize: CGFloat = 44
    /// The gap between the explanatory line and the step's controls (the prototype's `margin-top:12px`).
    public static let controlsSpacing: CGFloat = 12
    /// The gap between two parts of a step's controls.
    public static let itemSpacing: CGFloat = 14
}

/// One page of the welcome screen (prototype `shell-welcome-*`), shared by the shell's pages and every plugin's
/// onboarding step: the mark, the heading, one explanatory line in `secondaryText`, the step's controls, and
/// below a hairline the footer (Skip on the left, the one primary button on the right). The shell supplies the
/// mark and the footer, a plugin step only its controls (`OnboardingStep.makeView`) and its line
/// (`OnboardingStep.text`).
public struct WelcomeStepLayout<Mark: View, Content: View, Footer: View>: View {
    private let heading: String
    private let text: String?
    private let accessibilityLabel: String
    private let mark: Mark
    private let content: Content
    private let footer: Footer
    @Environment(\.lintelTextSize) private var textSize

    public init(
        heading: String,
        text: String?,
        accessibilityLabel: String,
        @ViewBuilder mark: () -> Mark,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.heading = heading
        self.text = text
        self.accessibilityLabel = accessibilityLabel
        self.mark = mark()
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                mark
                    .frame(width: WelcomeLayout.markSize, height: WelcomeLayout.markSize)
                    .padding(.bottom, 10)
                Text(heading)
                    .font(textSize.font(.title1, weight: .bold))
                    .foregroundStyle(LintelBrand.ink)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 4)
                if let text {
                    Text(text)
                        .foregroundStyle(LintelBrand.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, WelcomeLayout.contentInset)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
            // The prototype's footer border (`--hair`).
            LintelDivider()
            footer
        }
        .frame(width: WelcomeLayout.width)
        .frame(minHeight: WelcomeLayout.minHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The controls of a plugin's onboarding step in the welcome column: its parts one below the other, left
/// aligned, no icons, buttons in the prototype's `.btn` (`LintelSecondaryButtonStyle`) unless they set their own.
public struct WelcomeStepColumn<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: WelcomeLayout.itemSpacing) {
            content
        }
        .buttonStyle(LintelSecondaryButtonStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, WelcomeLayout.controlsSpacing)
    }
}

/// One part of an onboarding step: what it is for, then its control, or once it is done a checkmark in
/// `status.ok` with "Done" (or the part's own `doneText`).
public struct WelcomeStepItem<Control: View>: View {
    private let text: Text
    private let isDone: Bool
    private let doneText: Text?
    private let control: Control

    public init(_ text: Text, isDone: Bool = false, doneText: Text? = nil, @ViewBuilder control: () -> Control) {
        self.text = text
        self.isDone = isDone
        self.doneText = doneText
        self.control = control()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            text
                .foregroundStyle(LintelBrand.ink)
                .fixedSize(horizontal: false, vertical: true)
            if isDone {
                WelcomeStepDone(doneText)
            } else {
                control
            }
        }
        .accessibilityElement(children: .contain)
    }
}

extension WelcomeStepItem where Control == EmptyView {
    /// A part with nothing to do, only text (for example what is never recorded).
    public init(_ text: Text) {
        self.init(text) { EmptyView() }
    }
}

/// The finished state of a `WelcomeStepItem`.
public struct WelcomeStepDone: View {
    private let text: Text?

    public init(_ text: Text? = nil) {
        self.text = text
    }

    public var body: some View {
        Label {
            (text ?? Text("Done", comment: "Onboarding status of a finished step"))
                .foregroundStyle(LintelBrand.ink)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(LintelBrand.statusOk)
                .accessibilityHidden(true)
        }
    }
}

/// A side note under a step's parts: callout size in `secondaryText`.
public struct WelcomeStepNote: View {
    private let text: Text
    @Environment(\.lintelTextSize) private var textSize

    public init(_ text: Text) {
        self.text = text
    }

    public var body: some View {
        text
            .font(textSize.font(.callout))
            .foregroundStyle(LintelBrand.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
