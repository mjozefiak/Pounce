import AppKit
import Foundation
import LintelCore
import LintelKit
import Observation
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
        try Self.write(contents, to: url)
        return url
    }

    /// UTF-8, atomically, then readable by the user only: a meeting is private.
    static func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
        /// The notes are being written; `phase` says how far (`nil` when only the stored status is known).
        case notesWriting(NotesJobPhase?)
        case notesFailed
        /// Some parts of the recording could not be read, so the notes miss them.
        case notesPartial
        /// This many points of the model had no backing in the recording and were left out.
        case notesDropped(Int)
        /// Notes are on but their model is not downloaded.
        case notesNeedsModel
    }

    enum Feedback: Equatable {
        case copied
        case saved
        case saveFailed
        case finishUnavailable
        case actionFailed
        /// The meeting is still there: its audio could not be removed, or it is being processed.
        case deleteFailed
    }

    /// What "Dokończ" found that needs the user's decision: closing the meeting from its transcript leaves a
    /// gap where the audio could not be read.
    enum GapOffer: Equatable {
        /// The spool cannot be read for good.
        case audioUnreadable
        /// This many segments could not be transcribed or read.
        case unfinished(Int)
    }

    private(set) var phase = Phase.loading
    private(set) var document: MeetingDocument?
    private(set) var feedback: Feedback?
    private(set) var isFinishing = false
    private(set) var isDeleting = false
    private(set) var gapOffer: GapOffer?
    /// The title as typed in the field, not committed yet; `commitPendingTitle()` (window close) saves it.
    var pendingTitle: String?
    var isConfirmingDelete = false
    private(set) var isDeleted = false

    let meetingID: Int64

    @ObservationIgnored private let store: MeetingsStore
    @ObservationIgnored private let spool: any SpoolMaintenance
    @ObservationIgnored private let pasteboard: any PasteboardClient
    @ObservationIgnored private let saver: any FileSaver
    @ObservationIgnored private let finishMeeting: @MainActor (Int64, Bool) -> MeetingFinishHandle?
    @ObservationIgnored private let regenerate: (@MainActor (Int64) -> Void)?
    @ObservationIgnored private let notes: NotesBoard?
    @ObservationIgnored private let openNotesModel: @MainActor () -> Void
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var followTask: Task<Void, Never>?
    @ObservationIgnored private let onDeleted: @MainActor () -> Void
    @ObservationIgnored private let announce: @MainActor (String) -> Void
    @ObservationIgnored private let labels: MarkdownExporter.Labels
    @ObservationIgnored private let timeZone: TimeZone
    /// Bumped by every `load()`: a snapshot read before a newer one started never replaces it.
    @ObservationIgnored private var loadGeneration = 0
    /// Edits in flight; only the last one to finish reloads, after all of them are in the database.
    @ObservationIgnored private var pendingMutations = 0

    /// - Parameters:
    ///   - finish: "Dokończ" (`MeetingsLibrary.finish(meetingID:acceptGap:)`); `nil` handle when nothing can be finished now.
    ///   - regenerate: "Regeneruj notatki" (`NotesService.regenerate`); `nil` keeps the button disabled with an
    ///     explanation.
    ///   - notes: what the notes service does and whether its model is missing; the window follows a running
    ///     job by reloading while it lasts.
    init(
        meetingID: Int64, store: MeetingsStore, spool: any SpoolMaintenance, pasteboard: any PasteboardClient,
        saver: any FileSaver = SavePanelFileSaver(),
        finish: @escaping @MainActor (Int64, Bool) -> MeetingFinishHandle? = { _, _ in nil },
        regenerate: (@MainActor (Int64) -> Void)? = nil, onDeleted: @escaping @MainActor () -> Void = {},
        announce: @escaping @MainActor (String) -> Void = { _ in },
        labels: MarkdownExporter.Labels = .localized, timeZone: TimeZone = .current, notes: NotesBoard? = nil,
        openNotesModel: @escaping @MainActor () -> Void = {}, pollInterval: Duration = .seconds(2),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.notes = notes
        self.openNotesModel = openNotesModel
        self.pollInterval = pollInterval
        self.sleep = sleep
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

    /// Loads the meeting off the main actor. Overlapping loads: the newest one wins, an older snapshot that
    /// arrives late is dropped. (Nothing signals store changes to the window yet; the library calls `load()`
    /// again when it needs the window to follow, for example after step 1.10 wires the list.)
    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        let store = store
        let id = meetingID
        let result = await Task.detached { () -> Result<MeetingDocument?, any Error> in
            Result { try store.loadDocument(id: id) }
        }.value
        guard generation == loadGeneration, !isDeleted else { return }
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
        if let title = document.title.map(Self.visible), !title.isEmpty { return title }
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
        let phase = notes?.phase(of: meetingID)
        if phase != nil || document.notesStatus == .running {
            result.append(.notesWriting(phase))
        } else {
            switch document.notesStatus {
            case .failed: result.append(.notesFailed)
            case .partial: result.append(.notesPartial)
            case .stale where document.notesMarkdown != nil: result.append(.notesStale)
            case .none where document.status == .ready && notes?.snapshot.needsModel(for: meetingID) == true:
                result.append(.notesNeedsModel)
            default: break
            }
        }
        if document.notesDroppedCount > 0, document.notesMarkdown != nil, phase == nil {
            result.append(.notesDropped(document.notesDroppedCount))
        }
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
        if let label = document?.speaker(id: segment.speakerID).map({ Self.visible($0.label) }), !label.isEmpty {
            return label
        }
        return String(localized: "Unknown speaker", comment: "Meeting window: segment without a speaker")
    }

    /// The text without invisible characters, trimmed: empty when nothing visible is left.
    static func visible(_ text: String) -> String { MeetingEdits.visible(text) }

    /// "To ja" needs a speaker who is not "Ja" yet, and a meeting that is not in `channels` mode.
    func canMarkSelf(_ speaker: MeetingDocument.Speaker) -> Bool {
        guard let document else { return false }
        return document.speakerMode != .channels && !speaker.isSelf && document.status != .recording
    }

    var canCopy: Bool { document != nil && !isEmpty }
    var canSave: Bool { document != nil && !isEmpty }

    /// Works for a `ready` meeting whose notes are not being written right now (also stale and failed ones).
    var canRegenerate: Bool {
        guard regenerate != nil, document?.status == .ready else { return false }
        return document?.notesStatus != .running && notes?.phase(of: meetingID) == nil
    }
    var regenerateExplanation: String? {
        regenerate == nil
            ? String(
                localized: "Writing notes is not available.",
                comment: "Meeting window: why Regenerate notes is disabled") : nil
    }

    /// "Pobierz model notatek": opens the Settings of the notes.
    func downloadNotesModel() { openNotesModel() }

    var canDelete: Bool {
        guard let status = document?.status else { return false }
        return !status.isActive && !isFinishing && !isDeleting
    }

    // MARK: Editing

    func renameSpeaker(_ speakerID: Int64, to name: String) async {
        let trimmed = Self.visible(name)
        guard let current = document?.speaker(id: speakerID), !trimmed.isEmpty, trimmed != current.label else {
            return
        }
        let meetingID = meetingID
        await mutate { try MeetingEdits.renameSpeaker(speakerID, of: meetingID, to: trimmed, in: $0) }
    }

    func markSelf(_ speakerID: Int64) async {
        guard let speaker = document?.speaker(id: speakerID), canMarkSelf(speaker) else { return }
        let meetingID = meetingID
        await mutate {
            // A refusal (the meeting changed since the button was drawn) changes nothing, as before.
            do { try MeetingEdits.markSelf(speakerID, of: meetingID, in: $0) } catch MeetingEdits.Failure.refused {}
        }
    }

    func renameTitle(_ title: String) async {
        let id = meetingID
        pendingTitle = nil
        let trimmed = Self.visible(title)
        guard trimmed != (document?.title ?? "") else { return }
        await mutate { try MeetingEdits.renameTitle(id, to: trimmed, in: $0) }
    }

    /// Saves a title that was typed but not submitted (the window is closing).
    func commitPendingTitle() async {
        guard let pending = pendingTitle else { return }
        await renameTitle(pending)
    }

    /// Runs an edit off the main actor. Edits may overlap (a rename while another is still writing); each
    /// one counts itself in, and the last to finish reloads, so the screen shows the result of all of them.
    private func mutate(_ change: @escaping @Sendable (MeetingsStore) throws -> Void) async {
        let store = store
        pendingMutations += 1
        let succeeded = await Task.detached { (try? change(store)) != nil }.value
        pendingMutations -= 1
        if !succeeded {
            feedback = .actionFailed
        } else if pendingMutations == 0 {
            feedback = nil
        }
        if pendingMutations == 0 { await load() }
    }

    // MARK: Export

    /// The Markdown of the meeting as shown now.
    func markdown() -> String? {
        document.map { MarkdownExporter.export($0, labels: labels, timeZone: timeZone) }
    }

    /// "Kopiuj Markdown": the only place the pasteboard is touched, and only on this explicit action.
    func copyMarkdown() {
        guard canCopy, let text = markdown() else { return }
        // Marked transient and concealed: Lintel's own clipboard history (and other managers that honour
        // nspasteboard.org) skip it, so a meeting transcript is not stored a second time.
        pasteboard.write([
            PasteboardItem(representations: [
                PasteboardRepresentation(type: PasteboardRepresentation.plainTextType, data: Data(text.utf8)),
                PasteboardRepresentation(type: PasteboardRepresentation.transientMarkerType, data: Data()),
                PasteboardRepresentation(type: PasteboardRepresentation.concealedMarkerType, data: Data()),
            ])
        ])
        feedback = .copied
        announce(String(localized: "Copied Markdown", comment: "VoiceOver announcement after copying"))
    }

    static let maxFileNameScalars = 100

    func suggestedFileName() -> String {
        var base = Self.visible(title).replacing(/[\/:\\*?"<>| ]+/, with: " ")
        base = String(base.drop { $0 == "." || $0 == " " })
        base = String(base.unicodeScalars.prefix(Self.maxFileNameScalars))
        base = base.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix(".") { base.removeLast() }
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
        follow()
    }

    /// Reloads the meeting while its notes are written, so the banner and the status follow the job. Ends when
    /// the job has ended (or the window goes away).
    func followNotes() async {
        while !Task.isCancelled {
            guard notes?.phase(of: meetingID) != nil || document?.notesStatus == .running else { return }
            do { try await sleep(pollInterval) } catch { return }
            if Task.isCancelled { return }
            await load()
        }
    }

    /// Starts `followNotes()` once; the window's own task and a regenerate request both call it.
    func follow() {
        guard followTask == nil else { return }
        followTask = Task { [weak self] in
            await self?.followNotes()
            self?.followTask = nil
        }
    }

    func stopFollowing() {
        followTask?.cancel()
        followTask = nil
    }

    // MARK: Finishing and deleting

    /// "Dokończ": finishes an `incomplete` meeting from its spool, then reloads. When some audio cannot be read
    /// the meeting stays `incomplete` and `gapOffer` says so; `finish(acceptGap: true)` ("Zakończ z luką")
    /// closes it from the transcript anyway.
    func finish(acceptGap: Bool = false) async {
        guard !isFinishing, !isDeleting else { return }
        guard let handle = finishMeeting(meetingID, acceptGap) else {
            feedback = .finishUnavailable
            return
        }
        feedback = nil
        gapOffer = nil
        isFinishing = true
        for await _ in handle.events {}
        let outcome = await handle.outcome
        isFinishing = false
        switch outcome {
        case .incomplete(.audioUnreadable): gapOffer = .audioUnreadable
        case .incomplete(.unfinished(let count)): gapOffer = .unfinished(count)
        case .incomplete(.modelUnavailable), .unavailable, .databaseUnwritable, .failed, .notResumable:
            feedback = .finishUnavailable
        default: break
        }
        await load()
    }

    func requestDelete() {
        guard canDelete else { return }
        isConfirmingDelete = true
    }

    /// Deletes after the confirmation: the rows and the spool folder if one is left, in one step. When the
    /// audio cannot be removed, or the meeting became active meanwhile, nothing is deleted and `deleteFailed`
    /// says so.
    func confirmDelete() async {
        isConfirmingDelete = false
        guard canDelete else { return }
        isDeleting = true
        let store = store
        let spool = spool
        let id = meetingID
        let succeeded = await Task.detached { (try? store.deleteMeeting(id, spool: spool)) != nil }.value
        isDeleting = false
        guard succeeded else {
            feedback = .deleteFailed
            await load()
            return
        }
        isDeleted = true
        loadGeneration += 1
        document = nil
        phase = .missing
        onDeleted()
    }
}
