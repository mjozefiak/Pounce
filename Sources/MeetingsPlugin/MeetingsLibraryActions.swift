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
    /// again has a new store, and its windows start over.
    private var windows: (store: MeetingsStore, controller: MeetingWindowController)?
    /// False in QA mode: the window is ordered front without activating Pounce.
    var activatesApp = true

    /// Whether "Regenerate Notes" is offered: only once the notes pipeline gives a closure (Phase 2).
    nonisolated let canRegenerate: Bool

    init(
        library: MeetingsLibrary, pasteboard: any PasteboardClient, labels: MarkdownExporter.Labels = .localized,
        timeZone: TimeZone = .current, regenerate: (@MainActor (Int64) -> Void)? = nil,
        changed: @escaping @Sendable () -> Void = {}
    ) {
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
        let document = try await Task.detached { try store.loadDocument(id: id) }.value
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
            let library = library
            let pasteboard = pasteboard
            let labels = labels
            let timeZone = timeZone
            let regenerate = regenerateNotes
            let changed = changed
            let controller = MeetingWindowController { meetingID in
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

    /// ⌃X: deletes the meeting and its spool in one step. A meeting that is being recorded or finished is not
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
