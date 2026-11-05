import LintelKit
import LintelUI
import SwiftUI

/// The one status banner above a Settings pane in the main window (spec step 2.2), drawn by `SettingsHost`.
/// The glyph takes its colour from the `status.*` tokens; the text stays in the label colours. The icon, title
/// and detail are announced as one unit; the buttons (at most two, the first is primary) follow it.
struct StatusBanner: View {
    let banner: StatusDerivation.Banner
    /// True while an action runs: the buttons are disabled.
    let isBusy: Bool
    let onAction: (SettingsStatusAction) -> Void

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Self.glyph(banner.level, textSize: textSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: banner.title)
                        .font(textSize.font(.body, weight: .semibold))
                    if let detail = banner.detail {
                        Text(verbatim: detail)
                            .font(textSize.font(.callout))
                            .foregroundStyle(LintelBrand.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: banner.accessibilityLabel))
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("settings.banner.text")

            let actions = Array(banner.actions.prefix(StatusDerivation.maximumActions))
            HStack(spacing: 8) {
                ForEach(actions.indices, id: \.self) { index in
                    button(actions[index], primary: index == 0)
                }
            }
        }
        .padding(.vertical, Self.verticalPadding)
        .padding(.horizontal, 14)
        .background(Self.cardFill, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(Self.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.banner")
    }

    /// The prototype's `.bn`: a card like the grouped form's sections, with a hairline border.
    static let cornerRadius: CGFloat = 10
    /// Padding 10 plus the prototype's 1.45 line height, which the system text styles do not have.
    static let verticalPadding: CGFloat = 13
    /// The filled circle behind the glyph at Medium (prototype `.bn .g`, 1.9 em of 13 pt).
    static let glyphDiameter: CGFloat = 25
    /// The prototype's `--card` with a `--hair` border, like the grouped form's cards.
    static let cardFill = LintelBrand.card
    static let hairline = LintelBrand.hairline

    /// The level's colour as a filled circle with the glyph cut out in `onStatus`.
    static func glyph(_ level: SettingsStatus.Level, textSize: TextSize) -> some View {
        let diameter = (glyphDiameter * textSize.scale).rounded()
        return Circle()
            .fill(color(level))
            .frame(width: diameter, height: diameter)
            .overlay {
                Image(systemName: symbolName(level))
                    .font(.system(size: diameter * 0.5, weight: .bold))
                    .foregroundStyle(LintelBrand.onStatus)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func button(_ action: SettingsStatusAction, primary: Bool) -> some View {
        let label = Text(action.title).font(textSize.font(.callout)).lineLimit(1).fixedSize()
        if primary {
            Button {
                onAction(action)
            } label: {
                label
            }
            .buttonStyle(LintelPrimaryButtonStyle())
            .disabled(isBusy)
        } else {
            Button {
                onAction(action)
            } label: {
                label
            }
            .buttonStyle(LintelSecondaryButtonStyle())
            .disabled(isBusy)
        }
    }

    static func symbolName(_ level: SettingsStatus.Level) -> String {
        switch level {
        case .ok: "checkmark"
        case .attention: "exclamationmark"
        case .error: "xmark"
        case .neutral: "info"
        }
    }

    static func color(_ level: SettingsStatus.Level) -> Color {
        switch level {
        case .ok: LintelBrand.statusOk
        case .attention: LintelBrand.statusAttention
        case .error: LintelBrand.statusError
        // The prototype's `.bn .g` default: `--sec`.
        case .neutral: LintelBrand.secondaryText
        }
    }
}
