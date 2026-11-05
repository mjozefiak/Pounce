import SwiftUI

/// The one layout column of a settings pane. `SettingsPane`-style forms (grouped cards inset by `cardInset` on
/// each side) and the host's status banner read these values, so the banner's edges line up with the cards of
/// every pane. Below its width the column fills the width and the banner keeps the same `cardInset` margins as
/// the cards.
public nonisolated enum SettingsLayout {
    /// The width of a pane's column in the main window (`settingsColumn()`): cards of 640 pt, the prototype's
    /// `layout.settingsContent`.
    public static let mainColumnWidth: CGFloat = 680
    /// The horizontal margin between the form's edge and its grouped cards.
    public static let cardInset: CGFloat = 20
    /// The width of the cards and of the banner at full column width in the main window.
    public static var mainCardWidth: CGFloat { mainColumnWidth - 2 * cardInset }
}

extension View {
    /// Confines a main-window settings pane or banner to the shared column, centred, filling the width below it.
    public func settingsColumn() -> some View {
        frame(maxWidth: SettingsLayout.mainColumnWidth).frame(maxWidth: .infinity)
    }

    /// The banner variant of `settingsColumn()`: the same column, inset like the grouped cards.
    public func settingsBannerColumn() -> some View {
        padding(.horizontal, SettingsLayout.cardInset).settingsColumn()
    }
}
