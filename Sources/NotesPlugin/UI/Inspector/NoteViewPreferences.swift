import LintelKit
import Observation
import SwiftUI

/// The Details toggles of the inspector (prototype `lib-details`: "View"): author bars, source quotes and wrapped
/// lines. Stored in `plugins.notes.showAuthorBars`, `showQuotes` and `wrapLines` (declared once in
/// `NotesSettingsKey`); a toggle writes the setting at once. With no settings (tests, QA) they stay in memory.
@MainActor @Observable
final class NoteViewPreferences {
    var showAuthorBars: Bool {
        didSet { if showAuthorBars != oldValue { settings?.set(showAuthorBars, for: NotesSettingsKey.showAuthorBars) } }
    }
    var showQuotes: Bool {
        didSet { if showQuotes != oldValue { settings?.set(showQuotes, for: NotesSettingsKey.showQuotes) } }
    }
    var showComments: Bool {
        didSet { if showComments != oldValue { settings?.set(showComments, for: NotesSettingsKey.showComments) } }
    }
    var wrapLines: Bool {
        didSet { if wrapLines != oldValue { settings?.set(wrapLines, for: NotesSettingsKey.wrapLines) } }
    }

    @ObservationIgnored private let settings: PluginSettings?

    init(settings: PluginSettings? = nil) {
        self.settings = settings
        let current = settings.map(NotesSettings.init)
        showAuthorBars = current?.showAuthorBars ?? true
        showQuotes = current?.showQuotes ?? true
        showComments = current?.showComments ?? true
        wrapLines = current?.wrapLines ?? true
    }
}

extension EnvironmentValues {
    /// Whether the block being drawn may show its quote chips (the Details toggle and the block's own right).
    @Entry var noteShowsQuotes = true
}
