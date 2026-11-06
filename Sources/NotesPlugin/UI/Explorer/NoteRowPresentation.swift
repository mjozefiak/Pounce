import Foundation
import LintelKit

/// How bad a note's state is: the colour of the explorer dot and of the state line under the row.
enum NoteStateLevel: Sendable, Equatable {
    /// Finished, nothing to say: the quiet hairline dot.
    case quiet
    /// Work is going on (recording, processing, writing).
    case active
    /// Needs the user: partial, stale, interrupted, needs a model, recording removed, source off.
    case attention
    case error
}

/// What an explorer row and a tab show for a note, pure and localized through the main bundle. The text is
/// built from the note's metadata only; a title is other people's words and is passed through verbatim.
struct NoteRowPresentation: Sendable {
    var calendar: Calendar
    var locale: Locale

    init(calendar: Calendar = .current, locale: Locale = .current) {
        self.calendar = calendar
        self.locale = locale
    }

    // MARK: Title

    /// The title, or a name made of the kind and the start time when the note has none.
    func title(_ summary: NoteSummary) -> String {
        if let title = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let when = dateTime(summary.startedAt)
        switch summary.kind {
        case .meeting:
            return String(localized: "Meeting \(when)", comment: "Explorer: name of a meeting without a title")
        case .dictation:
            return String(localized: "Dictation \(when)", comment: "Explorer: name of a dictation without text")
        default: return String(localized: "Untitled note", comment: "Explorer: name of a note without a title")
        }
    }

    /// The last part of the path bar: a dictation is "Dictation 11:20" (its text is long), any other note its title.
    func pathTitle(_ summary: NoteSummary) -> String {
        guard summary.kind == .dictation else { return title(summary) }
        let when = time(summary.startedAt)
        return String(localized: "Dictation \(when)", comment: "Explorer: name of a dictation without text")
    }

    // MARK: Second line

    /// "14:05 · 42 min · Zoom": the time (the date too outside today and yesterday), the length and the app.
    func subtitle(_ summary: NoteSummary, showsDate: Bool) -> String {
        var parts = [showsDate ? dateTime(summary.startedAt) : time(summary.startedAt)]
        if let ms = summary.durationMs, ms > 0 { parts.append(duration(milliseconds: ms, kind: summary.kind)) }
        if let app = summary.sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
            parts.append(app)
        }
        return parts.joined(separator: " · ")
    }

    func duration(milliseconds: Int, kind: NoteKind) -> String {
        let value = Duration.milliseconds(milliseconds)
        if kind == .dictation || milliseconds < 60_000 {
            if milliseconds >= 3_600_000 {
                return value.formatted(
                    Duration.TimeFormatStyle(pattern: .hourMinuteSecond(padHourToLength: 1)).locale(locale))
            }
            return value.formatted(
                Duration.TimeFormatStyle(pattern: .minuteSecond(padMinuteToLength: 1)).locale(locale))
        }
        return value.formatted(
            Duration.UnitsFormatStyle(
                allowedUnits: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2
            ).locale(locale))
    }

    func time(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(
                date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }

    func dateTime(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .day().month(.abbreviated).hour().minute())
    }

    func dayAndTime(_ date: Date) -> String { dateTime(date) }

    // MARK: State

    static func level(_ badge: NoteBadge?) -> NoteStateLevel {
        guard let badge else { return .quiet }
        switch badge {
        case .recording, .processing, .writing: return .active
        case .partial, .stale, .interrupted, .needsModel, .recordingRemoved, .sourceOff: return .attention
        case .failed: return .error
        }
    }

    /// The state line of a row ("Writing notes 2 of 5"); `nil` for a finished note. The dot carries the colour,
    /// the words carry the meaning.
    static func stateText(_ badge: NoteBadge?) -> String? {
        guard let badge else { return nil }
        switch badge {
        case .recording:
            return String(localized: "Recording", comment: "Explorer: state line of a meeting being recorded")
        case .processing:
            return String(
                localized: "Processing the recording", comment: "Explorer: state line while the transcript is made")
        case .writing(let done, let total):
            return String(
                localized: "Writing notes \(done) of \(total)",
                comment: "Explorer: state line while the notes are written")
        case .partial:
            return String(localized: "Some notes are missing", comment: "Explorer: state line of partial notes")
        case .stale: return String(localized: "Notes are out of date", comment: "Explorer: state line of stale notes")
        case .interrupted:
            return String(
                localized: "Interrupted · finish it", comment: "Explorer: state line of an interrupted meeting")
        case .failed: return String(localized: "Notes failed", comment: "Explorer: state line of a failed note")
        case .needsModel:
            return String(
                localized: "Needs a notes model", comment: "Explorer: state line when the notes model is missing")
        case .recordingRemoved:
            return String(
                localized: "Recording removed", comment: "Explorer: state line of a kept copy without its recording")
        case .sourceOff:
            return String(
                localized: "Its source is off", comment: "Explorer: state line of a kept copy whose plugin is off")
        }
    }

    /// The whole row for VoiceOver: title, second line and state in words.
    func accessibilityLabel(_ row: NoteRow, showsDate: Bool, snippet: String? = nil) -> String {
        [title(row.summary), snippet ?? subtitle(row.summary, showsDate: showsDate), Self.stateText(row.badge)]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// Where the words of a search stand in a snippet: every word of the query, found without regard to case or
    /// accents, merged when they touch. Pure, so the highlight is tested without a view.
    static func highlightRanges(in snippet: String, query: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for word in query.split(whereSeparator: \.isWhitespace) {
            var from = snippet.startIndex
            while from < snippet.endIndex,
                let range = snippet.range(
                    of: word, options: [.caseInsensitive, .diacriticInsensitive], range: from..<snippet.endIndex)
            {
                found.append(range)
                from = range.upperBound
            }
        }
        found.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in found {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
