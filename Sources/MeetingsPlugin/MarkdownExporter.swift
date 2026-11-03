import Foundation

/// `Meeting → String` (spec: Architecture → `MarkdownExporter`). Pure and deterministic: the same document,
/// labels and time zone always give the same text.
///
/// Everything that comes from people or from a model is untrusted (a speaker may say "![x](http://…)"):
/// - titles, speaker names and transcript text are plain text. Their Markdown control characters are
///   escaped with a backslash, line breaks become spaces and invisible or bidirectional control characters
///   are removed, so they can never become a heading, a link, an image or HTML.
/// - the notes are Markdown that code composed from model output (Phase 2). Their structure (headings,
///   lists, emphasis) stays, but images and links are reduced to their text, reference definitions, comments,
///   HTML tags and autolinks are removed, so neither the export nor a viewer loads anything from the network.
enum MarkdownExporter {
    /// The words of the export. The app passes `localized`; golden tests use `english`.
    struct Labels: Sendable, Equatable {
        var date: String
        var duration: String
        var participants: String
        var notes: String
        var transcript: String
        var untitled: String
        var unknownSpeaker: String
        var staleNotes: String

        static let english = Labels(
            date: "Date", duration: "Duration", participants: "Participants", notes: "Notes",
            transcript: "Transcript", untitled: "Meeting", unknownSpeaker: "Unknown speaker",
            staleNotes: "These notes may be out of date: a speaker was renamed after they were written.")

        static var localized: Labels {
            Labels(
                date: String(localized: "Date", comment: "Markdown export: label of the meeting date"),
                duration: String(localized: "Duration", comment: "Markdown export: label of the meeting length"),
                participants: String(localized: "Participants", comment: "Markdown export: label of the speakers"),
                notes: String(localized: "Notes", comment: "Markdown export: heading of the meeting notes"),
                transcript: String(localized: "Transcript", comment: "Markdown export: heading of the transcript"),
                untitled: String(localized: "Meeting", comment: "Markdown export: title of a meeting without one"),
                unknownSpeaker: String(
                    localized: "Unknown speaker", comment: "Markdown export: segment without a speaker"),
                staleNotes: String(
                    localized: "These notes may be out of date: a speaker was renamed after they were written.",
                    comment: "Markdown export: note under the notes heading when a speaker was renamed"))
        }
    }

    static func export(
        _ meeting: MeetingDocument, labels: Labels = .english, timeZone: TimeZone = .current
    ) -> String {
        var lines: [String] = []
        let date = formatDate(meeting.startedAt, timeZone: timeZone)
        let title = plain(meeting.title ?? "")
        lines.append("# " + (title.isEmpty ? "\(plain(labels.untitled)) \(date)" : title))
        lines.append("")
        lines.append("- **\(plain(labels.date)):** \(date)")
        if meeting.durationMs > 0 {
            lines.append("- **\(plain(labels.duration)):** \(clock(milliseconds: meeting.durationMs))")
        }
        let participants = uniqueLabels(meeting.speakers)
        if !participants.isEmpty {
            lines.append("- **\(plain(labels.participants)):** " + participants.joined(separator: ", "))
        }
        if let notes = meeting.notesMarkdown.map(modelMarkdown), !notes.isEmpty {
            lines.append("")
            lines.append("## " + plain(labels.notes))
            lines.append("")
            if meeting.notesStatus == .stale {
                lines.append("> _" + plain(labels.staleNotes) + "_")
                lines.append("")
            }
            lines.append(notes)
        }
        let transcript = transcriptLines(meeting, unknown: plain(labels.unknownSpeaker))
        if !transcript.isEmpty {
            lines.append("")
            lines.append("## " + plain(labels.transcript))
            lines.append("")
            lines.append(contentsOf: transcript)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func transcriptLines(_ meeting: MeetingDocument, unknown: String) -> [String] {
        let names = Dictionary(
            meeting.speakers.map { ($0.id, plain($0.label)) }, uniquingKeysWith: { first, _ in first })
        let ordered = meeting.segments.enumerated().sorted {
            ($0.element.startMs, $0.element.id, $0.offset) < ($1.element.startMs, $1.element.id, $1.offset)
        }
        return ordered.compactMap { _, segment in
            let text = plain(segment.text)
            guard !text.isEmpty else { return nil }
            let name = segment.speakerID.flatMap { names[$0] }.flatMap { $0.isEmpty ? nil : $0 } ?? unknown
            return "[\(clock(milliseconds: segment.startMs))] \(name): \(text)"
        }
    }

    private static func uniqueLabels(_ speakers: [MeetingDocument.Speaker]) -> [String] {
        var seen = Set<String>()
        return speakers.map { plain($0.label) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: Formatting

    /// `hh:mm:ss`, hours growing past two digits when needed.
    static func clock(milliseconds: Int) -> String {
        let seconds = max(0, milliseconds) / 1000
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
    }

    private static func formatDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: Escaping

    /// Characters that can start Markdown or HTML structure inside a line.
    private static let markdownSpecials: Set<Character> = [
        "\\", "`", "*", "_", "[", "]", "(", ")", "<", ">", "#", "~", "|", "&", "!",
    ]

    /// Plain text on one line, safe to put anywhere in the document.
    static func plain(_ text: String) -> String {
        var result = ""
        for character in cleaned(text, keepNewlines: false) {
            if markdownSpecials.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Removes invisible and bidirectional control characters; line breaks become spaces unless kept.
    static func cleaned(_ text: String, keepNewlines: Bool) -> String {
        var result = String.UnicodeScalarView()
        var previousWasSpace = false
        for scalar in text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}" || scalar == "\u{85}" {
                if keepNewlines {
                    result.append("\n")
                    previousWasSpace = false
                } else if !previousWasSpace {
                    result.append(" ")
                    previousWasSpace = true
                }
                continue
            }
            if scalar == "\t" {
                result.append(" ")
                previousWasSpace = true
                continue
            }
            if isInvisible(scalar) { continue }
            result.append(scalar)
            previousWasSpace = scalar == " "
        }
        return String(result)
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: true
        case 0x00AD, 0x061C, 0x180E: true
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x206F, 0xFEFF: true
        case 0xFFF9...0xFFFB: true
        case 0xE0000...0xE007F: true
        default: false
        }
    }

    /// Model-composed notes: structure stays, everything that can load a resource or run markup goes.
    static func modelMarkdown(_ text: String) -> String {
        var result = cleaned(text, keepNewlines: true)
        result = result.replacing(/<!--[\s\S]*?-->/, with: "")
        // Images and links keep only their text. Repeated, so `[![a](u)](v)` ends as `a`.
        for _ in 0..<4 {
            let before = result
            result = result.replacing(/!?\[([^\]\n]*)\]\([^)\n]*\)/) { String($0.1) }
            result = result.replacing(/!?\[([^\]\n]*)\]\[[^\]\n]*\]/) { String($0.1) }
            if result == before { break }
        }
        result = result.replacing(/(?m)^[ ]{0,3}\[[^\]\n]+\]:[ \t]*\S.*$/, with: "")
        result = result.replacing(/<[A-Za-z][A-Za-z0-9+.\-]*:[^>\s]*>/, with: "")
        result = result.replacing(/<[^<>\s@]+@[^<>\s]+>/, with: "")
        result = result.replacing(/<\/?[A-Za-z!?][^>]*>/, with: "")
        result = result.replacing("<", with: "\\<")
        return result.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).replacing(/[ \t]+$/, with: "") }
            .joined(separator: "\n")
            .replacing(/\n{3,}/, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
