import AppKit
import Foundation
import Observation
import PounceKit
import UniformTypeIdentifiers

/// Saves an exported file. The system one shows an `NSSavePanel`; tests use a fake.
@MainActor
protocol FileSaver {
    /// Asks where to save and writes `contents` there. `nil` when the user cancelled.
    func save(_ contents: String, suggestedName: String) async throws -> URL?
}

/// "Zapisz .md…": the standard save panel, UTF-8 text.
@MainActor
struct SavePanelFileSaver: FileSaver {
    func save(_ contents: String, suggestedName: String) async throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Save", comment: "Button of the Markdown save panel")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// The state of one meeting window. All decisions live here so tests can check them without a view; the
/// view only draws the state and forwards actions.
@MainActor @Observable
final class MeetingWindowModel {
    enum Phase: Equatable {
        case loading
        case loaded
        /// The meeting is gone (deleted elsewhere, or the library is closed).
        case missing
        case failed
    }

    /// A notice above the transcript.
    enum Banner: Equatable {
        /// `speaker_mode = channels`: the speakers are the two tracks.
        case speakersUnavailable
        /// Recording was interrupted; "Dokończ" can finish it from the spool.
        case incomplete(canFinish: Bool)
        case finishing
        case failed
        case processing
        case notesStale
    }

    enum Feedback: Equatable {
        case copied
        case saved
        case saveFailed
        case finishUnavailable
        case actionFailed
    }

    private(set) var phase = Phase.loading
    private(set) var document: MeetingDocument?
    private(set) var feedback: Feedback?
    private(set) var isFinishing = false
    var isConfirmingDelete = false
    private(set) var isDeleted = false

    let meetingID: Int64

    @ObservationIgnored private let store: MeetingsStore
    @ObservationIgnored private let spool: any SpoolMaintenance
    @ObservationIgnored private let pasteboard: any PasteboardClient
    @ObservationIgnored private let saver: any FileSaver
    @ObservationIgnored private let finishMeeting: @MainActor (Int64) -> MeetingFinishHandle?
    @ObservationIgnored private let regenerate: (@MainActor (Int64) -> Void)?
    @ObservationIgnored private let onDeleted: @MainActor () -> Void
    @ObservationIgnored private let announce: @MainActor (String) -> Void
    @ObservationIgnored private let labels: MarkdownExporter.Labels
    @ObservationIgnored private let timeZone: TimeZone

    /// - Parameters:
    ///   - finish: "Dokończ" (`MeetingsLibrary.finish`); `nil` handle when nothing can be finished now.
    ///   - regenerate: "Regeneruj notatki"; `nil` until the notes pipeline exists (Phase 2), which keeps the
    ///     button disabled with an explanation.
    init(
        meetingID: Int64, store: MeetingsStore, spool: any SpoolMaintenance, pasteboard: any PasteboardClient,
        saver: any FileSaver = SavePanelFileSaver(),
        finish: @escaping @MainActor (Int64) -> MeetingFinishHandle? = { _ in nil },
        regenerate: (@MainActor (Int64) -> Void)? = nil, onDeleted: @escaping @MainActor () -> Void = {},
        announce: @escaping @MainActor (String) -> Void = { _ in },
        labels: MarkdownExporter.Labels = .localized, timeZone: TimeZone = .current
    ) {
        self.meetingID = meetingID
        self.store = store
        self.spool = spool
        self.pasteboard = pasteboard
        self.saver = saver
        finishMeeting = finish
        self.regenerate = regenerate
        self.onDeleted = onDeleted
        self.announce = announce
        self.labels = labels
        self.timeZone = timeZone
    }

    // MARK: Reading

    /// Loads the meeting off the main actor.
    func load() async {
        let store = store
        let id = meetingID
        let result = await Task.detached { () -> Result<MeetingDocument?, any Error> in
            Result { try store.loadDocument(id: id) }
        }.value
        switch result {
        case .success(let loaded?):
            document = loaded
            phase = .loaded
        case .success(nil):
            document = nil
            phase = .missing
        case .failure:
            // Keep what is on screen when a reload fails.
            if document == nil { phase = .failed }
        }
    }

    var title: String {
        guard let document else { return String(localized: "Meeting", comment: "Meeting window title while loading") }
        if let title = document.title, !title.isEmpty { return title }
        return Self.defaultTitle(for: document.startedAt, timeZone: timeZone)
    }

    static func defaultTitle(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatted = date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone))
        return String(localized: "Meeting \(formatted)", comment: "Title of a meeting without one; the date and time")
    }

    var isEmpty: Bool { phase == .loaded && document?.segments.isEmpty == true }

    var banners: [Banner] {
        guard let document else { return [] }
        var result: [Banner] = []
        switch document.status {
        case .incomplete:
            result.append(isFinishing ? .finishing : .incomplete(canFinish: document.audioState == .spool))
        case .failed: result.append(.failed)
        case .processing: result.append(.processing)
        case .recording, .ready: break
        }
        if document.speakerMode == .channels { result.append(.speakersUnavailable) }
        if document.notesStatus == .stale, document.notesMarkdown != nil { result.append(.notesStale) }
        return result
    }

    /// The speakers that appear in the transcript (or all of them when there is no transcript yet).
    var speakers: [MeetingDocument.Speaker] { document?.speakers ?? [] }

    /// Position of a speaker in the list; the colour band follows it.
    func colorIndex(of speakerID: Int64?) -> Int? {
        guard let speakerID, let index = speakers.firstIndex(where: { $0.id == speakerID }) else { return nil }
        return index
    }

    func speakerName(for segment: MeetingDocument.Segment) -> String {
        document?.speaker(id: segment.speakerID)?.label
            ?? String(localized: "Unknown speaker", comment: "Meeting window: segment without a speaker")
    }

    /// "To ja" needs a speaker who is not "Ja" yet, and a meeting that is not in `channels` mode.
    func canMarkSelf(_ speaker: MeetingDocument.Speaker) -> Bool {
        guard let document else { return false }
        return document.speakerMode != .channels && !speaker.isSelf && document.status != .recording
    }

    var canCopy: Bool { document != nil && !isEmpty }
    var canSave: Bool { document != nil && !isEmpty }

    /// The button is always there; it works once the notes pipeline is wired (Phase 2).
    var canRegenerate: Bool { regenerate != nil && document?.status == .ready }
    var regenerateExplanation: String? {
        regenerate == nil
            ? String(
                localized: "Notes are generated in a later version of Pounce.",
                comment: "Meeting window: why Regenerate notes is disabled") : nil
    }

    var canDelete: Bool {
        guard let status = document?.status else { return false }
        return !status.isActive
    }

    // MARK: Editing

    func renameSpeaker(_ speakerID: Int64, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = document?.speaker(id: speakerID), !trimmed.isEmpty, trimmed != current.label else {
            return
        }
        await mutate { try $0.renameSpeaker(speakerID, label: trimmed) }
    }

    func markSelf(_ speakerID: Int64) async {
        guard let speaker = document?.speaker(id: speakerID), canMarkSelf(speaker) else { return }
        await mutate { _ = try $0.markSelf(speakerID: speakerID) }
    }

    func renameTitle(_ title: String) async {
        let id = meetingID
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (document?.title ?? "") else { return }
        await mutate { try $0.renameMeeting(id, title: trimmed) }
    }

    private func mutate(_ change: @escaping @Sendable (MeetingsStore) throws -> Void) async {
        let store = store
        let succeeded = await Task.detached { (try? change(store)) != nil }.value
        feedback = succeeded ? nil : .actionFailed
        await load()
    }

    // MARK: Export

    /// The Markdown of the meeting as shown now.
    func markdown() -> String? {
        document.map { MarkdownExporter.export($0, labels: labels, timeZone: timeZone) }
    }

    /// "Kopiuj Markdown": the only place the pasteboard is touched, and only on this explicit action.
    func copyMarkdown() {
        guard canCopy, let text = markdown() else { return }
        pasteboard.setString(text)
        feedback = .copied
        announce(String(localized: "Copied Markdown", comment: "VoiceOver announcement after copying"))
    }

    func suggestedFileName() -> String {
        let base = title.replacing(/[\/:\\\n\r\t ]+/, with: " ").trimmingCharacters(in: .whitespaces)
        return (base.isEmpty ? "Meeting" : base) + ".md"
    }

    /// "Zapisz .md…"
    func saveMarkdown() async {
        guard canSave, let text = markdown() else { return }
        do {
            if try await saver.save(text, suggestedName: suggestedFileName()) != nil {
                feedback = .saved
                announce(String(localized: "Saved Markdown", comment: "VoiceOver announcement after saving"))
            }
        } catch {
            feedback = .saveFailed
        }
    }

    func regenerateNotes() {
        guard canRegenerate, let regenerate else { return }
        regenerate(meetingID)
    }

    // MARK: Finishing and deleting

    /// "Dokończ": finishes an `incomplete` meeting from its spool, then reloads.
    func finish() async {
        guard !isFinishing else { return }
        guard let handle = finishMeeting(meetingID) else {
            feedback = .finishUnavailable
            return
        }
        feedback = nil
        isFinishing = true
        for await _ in handle.events {}
        _ = await handle.outcome
        isFinishing = false
        await load()
    }

    func requestDelete() {
        guard canDelete else { return }
        isConfirmingDelete = true
    }

    /// Deletes after the confirmation: the rows and the spool folder if one is left.
    func confirmDelete() async {
        isConfirmingDelete = false
        guard canDelete else { return }
        let store = store
        let spool = spool
        let id = meetingID
        let succeeded = await Task.detached { (try? store.deleteMeeting(id, spool: spool)) != nil }.value
        guard succeeded else {
            feedback = .actionFailed
            return
        }
        isDeleted = true
        document = nil
        phase = .missing
        onDeleted()
    }
}
