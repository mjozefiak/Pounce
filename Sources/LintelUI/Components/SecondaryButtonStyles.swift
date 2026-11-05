import SwiftUI

/// The prototype's `.btn`: a card-coloured button with a hairline border, semibold ink text and 8 pt corners.
/// The main window's host applies it to every button that sets no style of its own, so the host's accent tint
/// (toggles, links, primary actions) no longer reaches secondary buttons. A button with the `.destructive`
/// role draws as `LintelDestructiveButtonStyle`.
public struct LintelSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.lintelTextSize) private var textSize

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        LintelBorderedButton.body(
            configuration, text: configuration.role == .destructive ? LintelBrand.statusError : LintelBrand.ink,
            isEnabled: isEnabled, textSize: textSize)
    }
}

/// The prototype's `.btn.dng`: the secondary button with `status.error` text, for the actions that delete data
/// (Clear History, Erase Data, Reset Ranking, the confirm button of a `ConfirmSheet`).
public struct LintelDestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.lintelTextSize) private var textSize

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        LintelBorderedButton.body(
            configuration, text: LintelBrand.statusError, isEnabled: isEnabled, textSize: textSize)
    }
}

/// The prototype's `.btn.dng.fill`: the confirm button of a destructive `ConfirmSheet`, `status.error` fill with
/// `onStatus` text (4.5:1 in both appearances, asserted in `BrandContrastTests`).
public struct LintelDestructiveProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.lintelTextSize) private var textSize

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LintelBorderedButton.font(textSize))
            .fontWeight(.semibold)
            .foregroundStyle(LintelBrand.onStatus)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                LintelBrand.statusError, in: RoundedRectangle(cornerRadius: LintelPrimaryButtonStyle.cornerRadius)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

enum LintelBorderedButton {
    /// The prototype's `.btn` font: the body size (`font: inherit`) in semibold, scaled by the text size. A label
    /// that sets its own font (the banner's buttons) keeps it.
    @MainActor static func font(_ textSize: TextSize) -> Font { textSize.font(.body, weight: .semibold) }

    @MainActor static func body(
        _ configuration: ButtonStyleConfiguration, text: Color, isEnabled: Bool, textSize: TextSize
    ) -> some View {
        configuration.label
            .font(font(textSize))
            .fontWeight(.semibold)
            .foregroundStyle(text)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                LintelBrand.card,
                in: RoundedRectangle(cornerRadius: LintelPrimaryButtonStyle.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LintelPrimaryButtonStyle.cornerRadius)
                    .strokeBorder(LintelBrand.hairline, lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

extension View {
    /// The red destructive button (`LintelDestructiveButtonStyle`).
    public func lintelDestructiveButton() -> some View { buttonStyle(LintelDestructiveButtonStyle()) }

    /// Ink instead of the accent for a control's value (menu pickers).
    public func lintelSecondaryTint() -> some View { tint(LintelBrand.ink) }
}
