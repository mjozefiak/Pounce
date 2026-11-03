import Foundation
import PounceKit

enum MeetingLibraryActionError: Error, Equatable {
    /// The library is closed or unavailable.
    case unavailable
    /// The meeting is gone.
    case missing
    /// The meeting has no transcript and no notes yet.
    case nothingToCopy
}

/// The meeting windows the actions open. The real one is `MeetingWindowController`; tests use a fake.
@MainActor
protocol MeetingWindowPresenting: AnyObject {
    var activatesApp: Bool { get set }
    func show(meetingID: Int64)
    func close(meetingID: Int64)
    func closeAll()
}

/// What the library list does with a meeting: copy it as Markdown, open its window, write the notes again,
/// delete it. Runs on the main actor; the heavy reads and the delete run off it.
@MainActor
final class MeetingsLibraryActions {
    private let library: MeetingsLibrary
    private let pasteboard: any PasteboardClient
    private let labels: MarkdownExporter.Labels
    private let timeZone: TimeZone
    private let regenerateNotes: (@MainActor (Int64) -> Void)?
    private let changed: @Sendable () -> Void
    /// The meeting windows belong to the store they were opened for: a library that was closed and opened
    /// again has a new store, and its windows start over (the old ones are closed first). The plugin owns the
    /// one `MeetingsLibraryActions`, so there is one window per meeting for the whole plugin.
    private var windows: (store: MeetingsStore, controller: any MeetingWindowPresenting)?
    private let makeWindows:
        @MainActor (@escaping @MainActor (Int64) -> MeetingWindowModel) -> any MeetingWindowPresenting
    /// ⌃X asks twice: the first press arms the meeting, the second one within `deleteConfirmationWindow` deletes.
    private var armedDelete: (id: Int64, deadline: Date)?
    private let now: () -> Date
    static let deleteConfirmationWindow: TimeInterval = 3
    /// False in QA mode: the window is ordered front without activating Pounce.
    var activatesApp = true

    /// Whether "Regenerate Notes" is offered: only once the notes pipeline gives a closure (Phase 2).
    nonisolated let canRegenerate: Bool

    init(
        library: MeetingsLibrary, pasteboard: any PasteboardClient, labels: MarkdownExporter.Labels = .localized,
        timeZone: TimeZone = .current, regenerate: (@MainActor (Int64) -> Void)? = nil,
        changed: @escaping @Sendable () -> Void = {}, now: @escaping () -> Date = { Date() },
        makeWindows:
            @escaping @MainActor (@escaping @MainActor (Int64) -> MeetingWindowModel) -> any MeetingWindowPresenting =
            { MeetingWindowController(makeModel: $0) }
    ) {
        self.now = now
        self.makeWindows = makeWindows
        self.library = library
        self.pasteboard = pasteboard
        self.labels = labels
        self.timeZone = timeZone
        regenerateNotes = regenerate
        canRegenerate = regenerate != nil
        self.changed = changed
    }

    /// Return: puts the meeting on the pasteboard as Markdown, marked transient and concealed so clipboard
    /// managers that honour nspasteboard.org (Pounce's own included) do not store a second copy.
    func copyMarkdown(_ id: Int64) async throws {
        guard let store = library.store else { throw MeetingLibraryActionError.unavailable }
        let document = try await MeetingLibraryIO.document(store: store, id: id)
        guard let document else { throw MeetingLibraryActionError.missing }
        guard !document.segments.isEmpty || document.notesMarkdown?.isEmpty == false else {
            throw MeetingLibraryActionError.nothingToCopy
        }
        let text = MarkdownExporter.export(document, labels: labels, timeZone: timeZone)
        MeetingPasteboard.writeMarkdown(text, to: pasteboard)
    }

    /// ⌘O: the meeting window (one per meeting, reused when it is open).
    func open(_ id: Int64) {
        guard let store = library.store else { return }
        if windows?.store !== store {
            windows?.controller.closeAll()
            windows = nil
            let library = library
            let pasteboard = pasteboard
            let labels = labels
            let timeZone = timeZone
            let regenerate = regenerateNotes
            let changed = changed
            let controller = makeWindows { meetingID in
                MeetingWindowModel(
                    meetingID: meetingID, store: store, spool: library.spoolStorage, pasteboard: pasteboard,
                    finish: { id, acceptGap in library.finish(meetingID: id, acceptGap: acceptGap) },
                    regenerate: regenerate,
                    onDeleted: {
                        library.refreshCount()
                        changed()
                    }, announce: MeetingWindowController.announce, labels: labels, timeZone: timeZone)
            }
            controller.activatesApp = activatesApp
            windows = (store, controller)
        }
        windows?.controller.show(meetingID: id)
    }

    /// ⌘R. Does nothing without a notes pipeline (the action is not offered then).
    func regenerate(_ id: Int64) {
        regenerateNotes?(id)
    }

    /// Closes every meeting window (the plugin deactivates, its data is erased or the store changes).
    func closeWindows() {
        windows?.controller.closeAll()
        windows = nil
        armedDelete = nil
    }

    /// ⌃X in the list: a meeting being recorded or processed is not touched and the panel says so; any other
    /// asks first ("Press ⌃X again to delete this meeting", and its audio when an unfinished one still has it) and
    /// deletes on the second press within a few seconds. A failed delete is explained, not a generic error.
    func requestDelete(_ id: Int64, panel: any PanelPresenter) async throws {
        guard let store = library.store else { throw MeetingLibraryActionError.unavailable }
        if library.protectedMeetingIDs.contains(id) {
            panel.showConfirmation(Self.activeMessage)
            return
        }
        if let armed = armedDelete, armed.id == id, armed.deadline >= now() {
            armedDelete = nil
            do {
                try await delete(id)
            } catch MeetingActionError.active {
                panel.showConfirmation(Self.activeMessage)
            } catch MeetingActionError.spoolNotRemoved {
                panel.showConfirmation(Self.notRemovedMessage)
            }
            return
        }
        armedDelete = nil
        let meeting = try await Task.detached { try store.recoverableMeeting(id: id) }.value
        guard let meeting else { throw MeetingLibraryActionError.missing }
        if meeting.status == .recording || meeting.status == .processing {
            panel.showConfirmation(Self.activeMessage)
            return
        }
        armedDelete = (id, now().addingTimeInterval(Self.deleteConfirmationWindow))
        panel.showConfirmation(
            meeting.audioState == .spool && meeting.status != .ready
                ? Self.confirmWithAudioMessage : Self.confirmMessage)
    }

    static let confirmMessage = LocalizedStringResource(
        "Press ⌃X again to delete this meeting.", comment: "Meeting library: asks to press Delete a second time")
    static let confirmWithAudioMessage = LocalizedStringResource(
        "Press ⌃X again to delete this meeting and its audio.",
        comment: "Meeting library: asks to press Delete again; the unfinished meeting's audio goes too")
    static let activeMessage = LocalizedStringResource(
        "A meeting that is being recorded or processed cannot be deleted.",
        comment: "Meeting library: Delete refused for a live meeting")
    static let notRemovedMessage = LocalizedStringResource(
        "The meeting was not deleted: its audio could not be removed. Try again.",
        comment: "Meeting window: the audio could not be removed, so the meeting stays")

    /// The deletion itself. A meeting that is being recorded or finished is not
    /// deleted (`MeetingActionError.active`); the shell says the action failed.
    func delete(_ id: Int64) async throws {
        guard let store = library.store else { throw MeetingLibraryActionError.unavailable }
        let spool = library.spoolStorage
        let existed = try await Task.detached { try store.deleteMeeting(id, spool: spool) }.value
        windows?.controller.close(meetingID: id)
        library.refreshCount()
        changed()
        if !existed { throw MeetingLibraryActionError.missing }
    }
}

/// Reads that follow the caller's cancellation (a stale preview load stops) and run off the main actor.
enum MeetingLibraryIO {
    @concurrent
    static func document(store: MeetingsStore, id: Int64) async throws -> MeetingDocument? {
        try Task.checkCancellation()
        let document = try store.loadDocument(id: id)
        try Task.checkCancellation()
        return document
    }
}

/// The one place the library writes to the pasteboard (the meeting window does the same on its own copy).
enum MeetingPasteboard {
    @MainActor
    static func writeMarkdown(_ text: String, to pasteboard: any PasteboardClient) {
        pasteboard.write([
            PasteboardItem(representations: [
                PasteboardRepresentation(type: PasteboardRepresentation.plainTextType, data: Data(text.utf8)),
                PasteboardRepresentation(type: PasteboardRepresentation.transientMarkerType, data: Data()),
                PasteboardRepresentation(type: PasteboardRepresentation.concealedMarkerType, data: Data()),
            ])
        ])
    }
}
