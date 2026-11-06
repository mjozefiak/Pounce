import Foundation
import Observation

/// What the History section of the Dictation pane shows and does: the switch, the retention choices and
/// "Clear History".
@MainActor @Observable
final class HistorySettingsModel {
    var isEnabled: Bool {
        didSet {
            settings.setHistoryEnabled(isEnabled)
            history.historyEnabledChanged()
        }
    }
    var retentionDays: Int {
        didSet {
            settings.setRetentionDays(retentionDays)
            history.applyRetention()
        }
    }
    var maximumEntries: Int {
        didSet {
            settings.setMaximumEntries(maximumEntries)
            history.applyRetention()
        }
    }
    private(set) var errorMessage: String?

    let history: DictationHistory
    @ObservationIgnored private let settings: DictationSettings

    init(settings: DictationSettings, history: DictationHistory) {
        self.settings = settings
        self.history = history
        isEnabled = settings.historyEnabled
        retentionDays = settings.retentionDays
        maximumEntries = settings.maximumEntries
    }

    /// "Clear History": every entry is deleted. `alsoDeleteKeptCopies` is the sheet's "Also delete kept copies"
    /// checkbox; ignored until Notes exists (spec `2026-11-04-notes-workspace`, step 4.6 deletes the copies).
    func clear(alsoDeleteKeptCopies: Bool = false) {
        do {
            try history.clear()
            errorMessage = nil
        } catch {
            errorMessage = String(
                localized: "The history could not be cleared.", comment: "Dictation settings error when clearing fails")
        }
    }

    /// The choices, with the current value added when it came from an older or hand-edited setting.
    func dayChoices() -> [Int] { Self.choices(DictationSettings.retentionDayChoices, including: retentionDays) }
    func entryChoices() -> [Int] { Self.choices(DictationSettings.maximumEntryChoices, including: maximumEntries) }

    static func choices(_ base: [Int], including value: Int) -> [Int] {
        base.contains(value) ? base : (base + [value]).sorted()
    }
}
