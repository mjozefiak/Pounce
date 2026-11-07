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

    /// How many copies of dictations Notes keeps because the user edited or commented on them ("N copies in Notes
    /// are kept"). Read before the Clear sheet opens (`refreshKeptCopies()`); 0 without Notes.
    private(set) var keptCopyCount = 0
    /// `PluginContext.keptNoteCopies` / `deleteKeptNoteCopies` for this plugin; the defaults mean "no Notes".
    @ObservationIgnored var keptCopies: @MainActor () async -> Int = { 0 }
    @ObservationIgnored var deleteKeptCopies: @MainActor () async -> Bool = { true }

    func refreshKeptCopies() async { keptCopyCount = await keptCopies() }

    /// "Clear History": every entry is deleted. `alsoDeleteKeptCopies` is the sheet's "Also delete kept copies"
    /// checkbox (off by default): the copies are removed through Notes ONLY when the box is ticked AND the history
    /// was cleared; the history is cleared first. The returned task is the copies' removal.
    @discardableResult
    func clear(alsoDeleteKeptCopies: Bool = false) -> Task<Void, Never>? {
        do {
            try history.clear()
            errorMessage = nil
        } catch {
            errorMessage = String(
                localized: "The history could not be cleared.", comment: "Dictation settings error when clearing fails")
            return nil
        }
        guard alsoDeleteKeptCopies else { return nil }
        return Task {
            if await !deleteKeptCopies() {
                errorMessage = String(
                    localized: "The history was cleared, but some copies in Notes could not be removed.",
                    comment: "Dictation settings error when Also delete kept copies fails after Clear History")
            }
            await refreshKeptCopies()
        }
    }

    /// The choices, with the current value added when it came from an older or hand-edited setting.
    func dayChoices() -> [Int] { Self.choices(DictationSettings.retentionDayChoices, including: retentionDays) }
    func entryChoices() -> [Int] { Self.choices(DictationSettings.maximumEntryChoices, including: maximumEntries) }

    static func choices(_ base: [Int], including value: Int) -> [Int] {
        base.contains(value) ? base : (base + [value]).sorted()
    }
}
