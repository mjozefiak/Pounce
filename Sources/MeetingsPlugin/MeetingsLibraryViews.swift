import Foundation
import SwiftUI

/// What the preview beside the library list shows for one meeting: the notes when there are any, else the
/// transcript. It is plain text: the notes and the transcript come from a model and from other people, so
/// they are cleaned of invisible and bidirectional control characters and shown verbatim. No Markdown is
/// rendered, so no link is active, no image loads and no request is made.
struct MeetingPreviewContent: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case notes
        case transcript
        /// Nothing to show yet; `text` says why.
        case placeholder
    }

    var kind: Kind
    /// A line above the text (stale or partial notes), or `nil`.
    var notice: String?
    var text: String
    var metadata: String
    /// The text was cut at `MeetingPreviewBuilder.maxCharacters`.
    var isTruncated: Bool
}

enum MeetingPreviewBuilder {
    /// A 3 hour transcript is far longer than a preview needs; the window shows all of it.
    static let maxCharacters = 20_000

    static func build(
        _ document: MeetingDocument, labels: MarkdownExporter.Labels = .localized, locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> MeetingPreviewContent {
        let metadata = MeetingLibraryPresentation.subtitle(
            .init(
                id: document.id, startedAt: document.startedAt, durationMs: document.durationMs,
                title: nil, sourceBundleID: nil, status: document.status, notesStatus: document.notesStatus,
                hasNotes: document.notesMarkdown?.isEmpty == false),
            locale: locale, timeZone: timeZone)
        if let notes = document.notesMarkdown {
            let text = MarkdownExporter.cleaned(notes, keepNewlines: true)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let (shown, truncated) = truncate(text)
                let stale = document.notesStatus == .stale ? labels.staleNotes : nil
                return .init(kind: .notes, notice: stale, text: shown, metadata: metadata, isTruncated: truncated)
            }
        }
        let transcript = transcript(document, unknown: labels.unknownSpeaker)
        if transcript.isEmpty {
            return .init(
                kind: .placeholder, notice: nil, text: placeholder(for: document.status), metadata: metadata,
                isTruncated: false)
        }
        let (shown, truncated) = truncate(transcript)
        return .init(kind: .transcript, notice: nil, text: shown, metadata: metadata, isTruncated: truncated)
    }

    /// `[hh:mm:ss] Name: text`, one line per segment in time order.
    static func transcript(_ document: MeetingDocument, unknown: String) -> String {
        let names = Dictionary(
            document.speakers.map { ($0.id, MeetingLibraryPresentation.visible($0.label)) },
            uniquingKeysWith: { first, _ in first })
        let ordered = document.segments.enumerated().sorted {
            ($0.element.startMs, $0.element.id, $0.offset) < ($1.element.startMs, $1.element.id, $1.offset)
        }
        var lines: [String] = []
        var length = 0
        for (_, segment) in ordered {
            let text = MeetingLibraryPresentation.visible(segment.text)
            guard !text.isEmpty else { continue }
            let name = segment.speakerID.flatMap { names[$0] }.flatMap { $0.isEmpty ? nil : $0 } ?? unknown
            let line = "[\(MarkdownExporter.clock(milliseconds: segment.startMs))] \(name): \(text)"
            lines.append(line)
            length += line.count + 1
            // Enough for the cut below; a very long transcript is not joined whole.
            if length > maxCharacters * 2 { break }
        }
        return lines.joined(separator: "\n")
    }

    private static func truncate(_ text: String) -> (String, Bool) {
        guard text.count > maxCharacters else { return (text, false) }
        return (String(text.prefix(maxCharacters)), true)
    }

    private static func placeholder(for status: MeetingStatus) -> String {
        switch status {
        case .recording:
            String(localized: "The meeting is being recorded.", comment: "Meeting library preview of a live meeting")
        case .processing:
            String(
                localized: "The transcript is being prepared.",
                comment: "Meeting library preview of a meeting being transcribed")
        case .ready, .incomplete, .failed:
            String(localized: "There is no transcript for this meeting.", comment: "Meeting window: no segments")
        }
    }
}

/// How a preview load ended.
enum MeetingPreviewLoad: Sendable, Equatable {
    case content(MeetingPreviewContent)
    /// The meeting is not in the library (deleted) or the library is not open.
    case missing
    /// The database could not be read.
    case failed
}

/// The preview beside the list. Loads the meeting off the main actor when the selection changes, and again
/// when the row's state changes (`refreshToken`: its badge and subtitle, so finished notes or a new status show).
struct MeetingLibraryPreview: View {
    let id: Int64?
    var refreshToken = ""
    let load: @Sendable (Int64) async -> MeetingPreviewLoad

    @State private var result: MeetingPreviewLoad?
    @State private var loadedID: Int64?

    private struct LoadKey: Hashable {
        var id: Int64?
        var token: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if loadedID == id, id != nil, let result {
                switch result {
                case .content(let content): contentView(content)
                case .missing:
                    message(
                        String(
                            localized: "This meeting is no longer in the library.",
                            comment: "Meeting library preview of a deleted meeting"))
                case .failed:
                    message(
                        String(
                            localized: "This meeting cannot be loaded right now.",
                            comment: "Meeting library preview when the database could not be read"))
                }
            } else {
                Color.clear
            }
        }
        .padding(12)
        .task(id: LoadKey(id: id, token: refreshToken)) {
            guard let id else {
                result = nil
                loadedID = nil
                return
            }
            let loaded = await load(id)
            guard !Task.isCancelled else { return }
            result = loaded
            loadedID = id
        }
    }

    private func message(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func contentView(_ content: MeetingPreviewContent) -> some View {
        if let notice = content.notice {
            Text(verbatim: notice).font(.callout).foregroundStyle(.secondary)
        }
        ScrollView {
            Text(verbatim: content.text)
                .foregroundStyle(content.kind == .placeholder ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            if content.isTruncated {
                Text(
                    "The text is shortened here. Open the meeting to read all of it.",
                    comment: "Meeting library preview: the text was cut"
                )
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .topLeading).padding(.top, 8)
            }
        }
        Divider()
        Text(verbatim: content.metadata).font(.callout).foregroundStyle(.secondary)
    }
}

/// Above the list: why the library is not available.
struct MeetingLibraryStatusView: View {
    let library: MeetingsLibrary

    var body: some View {
        if let text = MeetingLibraryMessages.unavailable(library.status) {
            Text(text).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}

/// Shown when the list is empty: the reason the library is unavailable, or that nothing was recorded yet.
struct MeetingLibraryEmptyView: View {
    let library: MeetingsLibrary

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.2.wave.2").font(.largeTitle).foregroundStyle(.secondary)
            Text(MeetingLibraryMessages.unavailable(library.status) ?? MeetingLibraryMessages.empty)
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

enum MeetingLibraryMessages {
    static var empty: String {
        String(
            localized: "No meetings yet. Start one with the Record Meeting command.",
            comment: "Meeting library empty state")
    }

    /// The explanation for a library that is not open, or `nil` when it is fine (or simply closed).
    static func unavailable(_ status: MeetingsLibrary.Status) -> String? {
        switch status {
        case .closed, .ready: nil
        case .unavailable:
            String(
                localized:
                    "The meeting library is unavailable because the Keychain could not be read. Nothing was deleted.",
                comment: "Meeting library banner when the Keychain key is unavailable")
        case .failed:
            String(
                localized: "The meeting library could not be opened.",
                comment: "Meeting library banner when the database could not be opened")
        }
    }
}
