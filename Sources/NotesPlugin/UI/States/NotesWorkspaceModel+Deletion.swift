import Foundation
import LintelKit

/// Delete (spec "Delete", prototype `dlg-delete-meeting`, `dlg-delete-dictation`): always behind a confirmation
/// sheet, the owner first and the overlays only after it succeeded, never while a meeting is being recorded or
/// processed. A refused or failed deletion changes nothing and says so in a strip.
extension NotesWorkspaceModel {
    /// What the confirmation sheet asks about. Holds the note's title, which is other people's words: never logged.
    struct DeleteRequest: Equatable, Identifiable {
        enum Subject: Equatable {
            case meeting, dictation, manual
            /// The edited copy of a recording that is gone ("Recording removed").
            case copy
        }
        var id: NoteItemID
        var title: String
        var subject: Subject
        /// A copy in Notes (user writing) goes too: the sheet says so.
        var hasEdits: Bool
    }

    /// Whether Delete is offered for the note: not while it is being recorded or processed (the owner refuses
    /// those), and only where the section can delete at all.
    func canDelete(_ id: NoteItemID) -> Bool {
        guard environment.canDeleteNotes else { return false }
        switch row(for: id)?.summary.state ?? documents[id]?.state {
        case .recording?, .processing?: return false
        default: return true
        }
    }

    /// ⌘⌫ in the explorer, the row's menu and "Delete…" in Details: builds the request, which the sheet shows.
    func requestDelete(_ id: NoteItemID) async {
        guard canDelete(id) else { return }
        let summary = row(for: id)?.summary ?? documents[id]?.summary
        let heads = await environment.overlayHeads(id)
        let subject: DeleteRequest.Subject
        switch id {
        case .detached: subject = .copy
        case .live(let key) where key.pluginID == NotesStore.manualPluginID: subject = .manual
        case .live: subject = (summary?.kind ?? .meeting) == .dictation ? .dictation : .meeting
        }
        let title = summary.map(presentation.title) ?? tabs.tabs.first { $0.id == id }?.title ?? id.key.rawValue
        pendingDelete = DeleteRequest(id: id, title: shown(title), subject: subject, hasEdits: !heads.isEmpty)
    }

    func cancelDelete() { pendingDelete = nil }

    /// The sheet's confirm button. The owner deletes first; only on success the tab closes and the copy goes.
    /// The sheet hands the request over itself: closing the sheet clears `pendingDelete` before this task runs.
    func confirmDelete(_ request: DeleteRequest) async {
        pendingDelete = nil
        do {
            try await environment.deleteNote(request.id)
        } catch let failure as NoteDeleter.Failure {
            switch failure {
            case .overlaysNotRemoved:
                // The owner deleted it: the note is gone, only the copy in Notes stays until the next sweep.
                dropTab(request.id)
                show(.copyNotRemoved)
                await refresh()
            default:
                show(.deleteFailed)
            }
            return
        } catch {
            show(.deleteFailed)
            return
        }
        dropTab(request.id)
        show(.deleted)
        await refresh()
    }

    /// The registry discarded these documents behind the UI's back: their tabs close and the list is read again.
    func documentsDiscarded(_ items: Set<NoteItemID>) {
        for id in items { dropTab(id) }
        Task { await refresh() }
    }
}
