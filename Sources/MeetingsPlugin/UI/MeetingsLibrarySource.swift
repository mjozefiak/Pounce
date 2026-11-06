import AppKit
import Foundation
import LintelKit
import os

/// The meeting library's results (spec step 1.11): newest first, optionally narrowed by a filter and by a
/// query that matches the title, the notes and the transcript through the two FTS5 indexes. The shell keeps
/// this order. Nothing here reads or writes `ranking.sqlite` and `PluginContext.usage` is never called.
struct MeetingsLibrarySource: PanelModeSource {
    /// The shell asks for at most this many rows (`SearchCoordinator.modeLimit`); the list is not paged.
    static let maxRows = 1000

    /// The open store, or `nil` while the library is closed or unavailable (a Keychain error, a failed open).
    let store: @MainActor @Sendable () -> MeetingsStore?
    let actions: MeetingsLibraryActions
    var timeZone: TimeZone = .current
    var locale: Locale = .current
    /// The display name of an installed app for the bundle ID a meeting was started from.
    var appName: @Sendable (String) -> String? = MeetingLibraryPresentation.installedAppName
    /// What the notes service is doing and whether its model is missing; `nil` shows the stored status only.
    var notes: NotesBoard?
    /// `PluginContext.openModels` for the notes model ("Download Notes Model").
    var openNotesModel: @MainActor @Sendable () -> Void = {}

    func search(_ query: NormalizedQuery, filter: PanelModeFilter.ID?, limit: Int) async throws -> [Candidate] {
        guard let store = await store() else { return [] }
        let filter = filter.flatMap(MeetingLibraryFilter.init(rawValue:)) ?? .all
        try Task.checkCancellation()
        let entries = try store.libraryEntries(
            matching: query.isEmpty ? nil : query.raw, filter: filter, limit: min(max(0, limit), Self.maxRows))
        try Task.checkCancellation()
        let snapshot = notes?.snapshot
        return entries.map { entry in
            Candidate(
                itemKey: MeetingLibraryPresentation.itemKey(entry.id),
                title: MeetingLibraryPresentation.title(entry, timeZone: timeZone),
                subtitle: MeetingLibraryPresentation.subtitle(
                    entry, locale: locale, timeZone: timeZone, appName: appName),
                icon: .symbol(MeetingLibraryPresentation.symbol(entry)),
                match: MatchResult(tier: .exact, score: 0),
                badge: MeetingLibraryPresentation.badge(
                    entry, phase: snapshot?.phases[entry.id],
                    needsNotesModel: snapshot?.needsModel(for: entry.id) ?? false))
        }
    }

    /// Return copies the Markdown, ⌘Return (and ⌘O) opens the meeting window, ⌘R writes the notes again,
    /// "Download Notes Model" appears on a meeting that waits for the model, and ⌃X deletes the meeting.
    func actions(for candidate: Candidate) -> [ResultAction] {
        guard let id = MeetingLibraryPresentation.meetingID(candidate.itemKey) else { return [] }
        let actions = actions
        var result = [
            ResultAction(
                id: "meetings.library.copy",
                title: LocalizedStringResource(
                    "Copy Markdown", comment: "Meeting library action that copies the meeting as Markdown"),
                symbolName: "doc.on.clipboard"
            ) { context in
                try await actions.copyMarkdown(id)
                await context.panel.showConfirmation(
                    LocalizedStringResource(
                        "Copied Markdown", comment: "Confirmation after copying a meeting as Markdown"))
            },
            ResultAction(
                id: "meetings.library.open",
                title: LocalizedStringResource(
                    "Open Meeting", comment: "Meeting library action that opens the meeting window"),
                symbolName: "macwindow",
                shortcut: KeyShortcut(key: "o", modifiers: .command)
            ) { _ in await actions.open(id) },
        ]
        if actions.canRegenerate {
            result.append(
                ResultAction(
                    id: "meetings.library.regenerate",
                    title: LocalizedStringResource(
                        "Regenerate Notes", comment: "Meeting library action that writes the notes again"),
                    symbolName: "arrow.triangle.2.circlepath",
                    shortcut: KeyShortcut(key: "r", modifiers: .command)
                ) { _ in await actions.regenerate(id) })
        }
        if notes?.snapshot.needsModel(for: id) == true, candidate.badge == MeetingLibraryPresentation.needsModelBadge {
            let openNotesModel = openNotesModel
            result.append(
                ResultAction(
                    id: "meetings.library.notesModel",
                    title: LocalizedStringResource(
                        "Download Notes Model", comment: "Meeting library action that opens the notes model settings"),
                    symbolName: "arrow.down.circle"
                ) { _ in await openNotesModel() })
        }
        result.append(
            ResultAction(
                id: "meetings.library.delete",
                title: LocalizedStringResource("Delete", comment: "Meeting library action that deletes the meeting"),
                symbolName: "trash",
                shortcut: KeyShortcut(key: "x", modifiers: .control),
                keepsPanelOpen: true
            ) { context in try await actions.requestDelete(id, panel: context.panel) })
        return result
    }
}

/// How a library row looks: pure functions of the row, testable without a store.
enum MeetingLibraryPresentation {
    static let pluginID: PluginID = "meetings"

    static func itemKey(_ id: Int64) -> ItemKey { ItemKey(pluginID: pluginID, key: "meeting:\(id)") }

    static func meetingID(_ key: ItemKey) -> Int64? {
        guard key.pluginID == pluginID, key.key.hasPrefix("meeting:") else { return nil }
        return Int64(key.key.dropFirst("meeting:".count))
    }

    /// The text without invisible characters, trimmed (what the meeting window shows too).
    static func visible(_ text: String) -> String {
        MarkdownExporter.cleaned(text, keepNewlines: false).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The title as typed, or "Meeting 3 Nov, 2:05 PM" (in the system language) when there is none.
    static func title(_ entry: MeetingLibraryEntry, timeZone: TimeZone = .current) -> String {
        if let title = entry.title.map(visible), !title.isEmpty { return title }
        let formatted = entry.startedAt.formatted(dateStyle(locale: nil, timeZone: timeZone))
        return String(localized: "Meeting \(formatted)", comment: "Title of a meeting without one; the date and time")
    }

    /// "3 Nov 2026, 2:05 PM · 1 hr, 5 min · Zoom": the date, how long it ran and the app it was started from.
    static func subtitle(
        _ entry: MeetingLibraryEntry, locale: Locale = .current, timeZone: TimeZone = .current,
        appName: (String) -> String? = { _ in nil }
    ) -> String {
        var parts = [date(entry.startedAt, locale: locale, timeZone: timeZone)]
        if let duration = duration(milliseconds: entry.durationMs, locale: locale) { parts.append(duration) }
        if let name = entry.sourceBundleID.flatMap(appName).map(visible), !name.isEmpty {
            parts.append(name)
        }
        return parts.joined(separator: " · ")
    }

    static func date(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        date.formatted(dateStyle(locale: locale, timeZone: timeZone))
    }

    private struct StyleKey: Hashable {
        var locale: String?
        var timeZone: String
    }

    private static let dateStyles = OSAllocatedUnfairLock(initialState: [StyleKey: Date.FormatStyle]())

    /// One format style per locale and time zone: a list of a thousand rows builds it once, not a thousand times.
    private static func dateStyle(locale: Locale?, timeZone: TimeZone) -> Date.FormatStyle {
        let key = StyleKey(locale: locale?.identifier, timeZone: timeZone.identifier)
        return dateStyles.withLock { styles in
            if let style = styles[key] { return style }
            let style =
                locale.map { Date.FormatStyle(date: .abbreviated, time: .shortened, locale: $0, timeZone: timeZone) }
                ?? Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone)
            styles[key] = style
            return style
        }
    }

    /// Whole minutes and hours ("1 hr, 5 min"), seconds under a minute, `nil` when nothing was recorded.
    static func duration(milliseconds: Int, locale: Locale = .current) -> String? {
        let seconds = milliseconds / 1000
        guard seconds > 0 else { return nil }
        if seconds < 60 {
            return Duration.seconds(seconds).formatted(
                .units(allowed: [.seconds], width: .abbreviated).locale(locale))
        }
        return Duration.seconds(seconds / 60 * 60).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2).locale(locale))
    }

    /// The badge of a meeting that waits for the notes model.
    static var needsModelBadge: String {
        String(localized: "Notes model needed", comment: "Meeting library badge: notes are on but the model is missing")
    }

    /// One short label: the state of an unfinished meeting, else the state of its notes (nothing before notes
    /// exist). `phase` is what a running notes job does right now; `needsNotesModel` says that notes are on and
    /// their model is not downloaded.
    static func badge(
        _ entry: MeetingLibraryEntry, phase: NotesJobPhase? = nil, needsNotesModel: Bool = false
    ) -> String? {
        switch entry.status {
        case .recording: return String(localized: "Recording", comment: "Meeting library badge: being recorded")
        case .processing: return String(localized: "Processing", comment: "Meeting library badge: being transcribed")
        case .incomplete:
            return String(localized: "Incomplete", comment: "Meeting library badge: recording was interrupted")
        case .failed: return String(localized: "Failed", comment: "Meeting library badge: meeting could not be made")
        case .ready: break
        }
        if let phase { return notesBadge(for: phase) }
        switch entry.notesStatus {
        case .none: return needsNotesModel ? needsModelBadge : nil
        case .running: return String(localized: "Writing notes", comment: "Meeting library badge: notes in progress")
        case .ok: return String(localized: "Notes", comment: "Meeting library badge: the meeting has notes")
        case .partial:
            return String(localized: "Partial notes", comment: "Meeting library badge: notes miss some parts")
        case .failed: return String(localized: "Notes failed", comment: "Meeting library badge: notes failed")
        case .stale:
            return String(localized: "Notes outdated", comment: "Meeting library badge: a speaker was renamed")
        }
    }

    /// "Czeka na model", "Pisanie notatek 2 z 8" and the like.
    static func notesBadge(for phase: NotesJobPhase) -> String {
        switch phase {
        case .queued:
            String(localized: "Notes queued", comment: "Meeting library badge: notes wait for their turn")
        case .waitingForModel:
            String(
                localized: "Waiting for the model", comment: "Meeting library badge: another model is in use")
        case .mapping(let done, let total):
            total > 0
                ? String(
                    localized: "Writing notes \(min(done + 1, total)) of \(total)",
                    comment: "Meeting library badge: notes in progress, the part being read")
                : String(localized: "Writing notes", comment: "Meeting library badge: notes in progress")
        case .reducing:
            String(localized: "Finishing notes", comment: "Meeting library badge: the last step of the notes")
        }
    }

    static func symbol(_ entry: MeetingLibraryEntry) -> String {
        switch entry.status {
        case .recording: "record.circle"
        case .processing: "hourglass"
        case .incomplete: "exclamationmark.triangle"
        case .failed: "xmark.octagon"
        case .ready: entry.hasNotes ? "doc.text" : "text.alignleft"
        }
    }

    /// The display name of the installed app with that bundle ID, without `.app`; `nil` when it is not installed.
    ///
    /// Asked once per bundle ID while the process runs (the list asks for every row on every keystroke and
    /// Launch Services is not free); an app installed later shows up after the next launch of Lintel.
    static func installedAppName(_ bundleID: String) -> String? {
        if let cached = appNames.withLock({ $0[bundleID] }) { return cached.name }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { $0.deletingPathExtension().lastPathComponent }
        appNames.withLock { $0[bundleID] = CachedName(name: name) }
        return name
    }

    private struct CachedName: Sendable { var name: String? }
    private static let appNames = OSAllocatedUnfairLock(initialState: [String: CachedName]())
}
