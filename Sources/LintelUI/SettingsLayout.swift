import SwiftUI

/// The one layout column of a settings pane. `SettingsPane`-style forms (width `columnWidth`, grouped cards
/// inset by `cardInset` on each side) and the host's status banner read these values, so the banner's edges
/// line up with the cards of every pane. Below `columnWidth` the column fills the width and the banner keeps
/// the same `cardInset` margins as the cards.
public nonisolated enum SettingsLayout {
    /// The width of a pane's form, which the old window also fixes its panes to.
    public static let columnWidth: CGFloat = 600
    /// The horizontal margin between the form's edge and its grouped cards.
    public static let cardInset: CGFloat = 20
    /// The width of the cards and of the banner at full column width.
    public static var cardWidth: CGFloat { columnWidth - 2 * cardInset }
}

extension View {
    /// Confines a settings pane or banner to the shared column, centred, filling the width below it.
    public func settingsColumn() -> some View {
        frame(maxWidth: SettingsLayout.columnWidth).frame(maxWidth: .infinity)
    }

    /// The banner variant of `settingsColumn()`: the same column, inset like the grouped cards.
    public func settingsBannerColumn() -> some View {
        padding(.horizontal, SettingsLayout.cardInset).settingsColumn()
    }
}
