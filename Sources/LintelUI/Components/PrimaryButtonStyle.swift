import SwiftUI

/// The prototype's primary button (`.btn.pri`): accent fill, `onAccent` text, 8 pt corners. Used for the one
/// action the user has to take (Download on a needed model); secondary actions stay `.bordered`.
public struct LintelPrimaryButtonStyle: ButtonStyle {
    /// Corner radius of the prototype's `.btn`.
    public static let cornerRadius: CGFloat = 8

    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(LintelBrand.onAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(LintelBrand.accent, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}
