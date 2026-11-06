import Foundation
import Testing

@testable import LintelUI

@Suite("Settings layout")
struct SettingsLayoutTests {
    @Test func cardsAreTheColumnMinusTheInsets() {
        #expect(SettingsLayout.mainCardWidth == SettingsLayout.mainColumnWidth - 2 * SettingsLayout.cardInset)
    }

    /// The cards are the prototype's 640 pt (`layout.settingsContent`).
    @Test func theCardsMatchThePrototype() {
        #expect(SettingsLayout.mainCardWidth == 640)
    }

    @Test func thePaneTitleIsTwentyPointsAtMedium() {
        #expect(22 * TextSize.paneTitleRatio == 20)
    }
}
