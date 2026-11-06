import Foundation
import LintelKit

/// What the workspace hands the revise service for one run: the layer document, its lock, and which threads.
struct ReviseCall {
    var item: NoteItemID
    var layer: String
    var lock: EditLock
    var threads: Set<Int64>?
}

/// "Revise with N comments" and "Ask agent" (step 6.2): the workspace asks the service, shows the lock strip while it
/// runs and the report strips afterwards. Nothing here reads or logs a note, a comment or an answer.
extension NotesWorkspaceModel {
    /// The N of "Revise with N comments": the open threads of the note on screen that a run would revise.
    var reviseCount: Int { currentDocument?.revisableCommentCount ?? 0 }

    /// The button is on when there is something to revise, the agent is wired and no run is going on in the note.
    var canRevise: Bool {
        guard let document = currentDocument else { return false }
        return reviseCount > 0 && environment.revise != nil && environment.canEditNotes
            && canWriteComments(document)
    }

    /// "Ask agent" on one thread: revises only that thread; queued behind a run that is going on.
    func canAskAgent(_ document: NoteDocumentModel) -> Bool {
        environment.revise != nil && environment.canEditNotes && canWriteCommentsIgnoringLock(document)
    }

    func isAskQueued(_ document: NoteDocumentModel, thread: CommentThread) -> Bool {
        environment.isReviseQueued(document.id, thread.id)
    }

    func revise() async {
        guard canRevise else { return }
        await runRevise(threads: nil)
    }

    func askAgent(_ thread: CommentThread) async {
        guard let document = currentDocument, canAskAgent(document), thread.isOpen else { return }
        await runRevise(threads: [thread.id])
    }

    /// Cancel of the lock strip: stops between two tokens; the document is unchanged.
    func cancelRevise() {
        guard let id = currentID else { return }
        environment.cancelRevise(id)
    }

    private func runRevise(threads: Set<Int64>?) async {
        guard let id = currentID, let document = documents[id], let layer = document.layerID,
            let run = environment.revise
        else { return }
        document.setReviseReport(nil)
        let wasEditing = document.isEditing
        let outcome = await run(ReviseCall(item: id, layer: layer, lock: document.lock, threads: threads))
        // A request that was queued is answered by the run that was going on.
        if outcome == .queued { return }
        document.lock.reset()
        guard documents[id] === document else { return }
        if outcome != .cancelled { document.setReviseReport(outcome) }
        if case .applied = outcome {
            // The editor is built again on the new text: its undo stack is cleared (spec "Edit lock and revise run").
            document.leaveEditing(notifying: false)
            await loadContent(id)
            await loadHistory(for: id)
            if wasEditing { beginEditing(id) }
        } else {
            await refreshComments(id)
        }
    }

    // MARK: Strips

    /// The lock strip while a run is going on, and how the last run ended.
    func reviseStrips(for document: NoteDocumentModel) -> [Strip] {
        var result: [Strip] = []
        switch document.lock.phase {
        case .flushing, .waitingForModel:
            result.append(
                Strip(
                    id: "revise.waiting", tone: .accent,
                    text: String(
                        localized: "Waiting for the model",
                        comment: "Notes: strip while the agent waits for the notes model (busy or used by dictation)"),
                    actions: [Self.cancelAction]))
        case .generating, .validating, .applying:
            result.append(
                Strip(
                    id: "revise.writing", tone: .accent,
                    text: String(
                        localized: "Agent is writing notes · read-only until it finishes",
                        comment: "Notes: lock strip while the agent revises the commented blocks"),
                    actions: [Self.cancelAction]))
        default: break
        }
        guard !document.lock.isActive, let report = document.reviseReport else { return result }
        result.append(contentsOf: Self.reportStrips(report))
        return result
    }

    private static var cancelAction: Strip.Action {
        Strip.Action(id: "revise.cancel", title: String(localized: "Cancel", comment: "Notes: stops the agent"))
    }

    private static var tryAgain: Strip.Action {
        Strip.Action(
            id: "revise.retry", title: String(localized: "Try again", comment: "Notes: strip action that tries the failed step again"))
    }

    static func reportStrips(_ outcome: ReviseOutcome) -> [Strip] {
        switch outcome {
        case .applied(let applied):
            var result = [
                Strip(
                    id: "revise.done", tone: .accent,
                    text: String(
                        localized: "Revised \(applied.blocks) blocks from comments. Restore is in History.",
                        comment: "Notes: strip after the agent revised the commented blocks"),
                    isDismissible: true)
            ]
            if applied.rejected > 0 {
                result.append(
                    Strip(
                        id: "revise.rejected.blocks", tone: .attention,
                        text: String(
                            localized: "\(applied.rejected) blocks couldn’t be revised and were left as they are.",
                            comment: "Notes: strip when the guard rejected the agent's answer for some blocks"),
                        isDismissible: true))
            }
            if applied.unresolved > 0 {
                result.append(
                    Strip(
                        id: "revise.unresolved", tone: .attention,
                        text: String(
                            localized: "\(applied.unresolved) comments couldn’t be resolved and stay open.",
                            comment: "Notes: strip when a revised comment thread changed or could not be resolved"),
                        isDismissible: true))
            }
            return result + skipStrips(applied.skipped)
        case .nothingToRevise(let skipped):
            return skipStrips(skipped)
        case .nothingToChange(let skipped):
            return [
                Strip(
                    id: "revise.nothingToChange", tone: .accent,
                    text: String(
                        localized: "The agent found nothing to change. The comments stay open.",
                        comment: "Notes: strip when the agent left every commented block as it was"),
                    isDismissible: true)
            ] + skipStrips(skipped)
        case .needsModel:
            return [
                Strip(
                    id: "revise.needsModel", tone: .attention,
                    text: String(
                        localized: "Notes need a model. It downloads once and runs on this Mac.",
                        comment: "Notes: strip when the notes model is missing"),
                    actions: [
                        Strip.Action(
                            id: "models.open",
                            title: String(localized: "Open Models", comment: "Notes: opens the Models pane"))
                    ], isDismissible: true)
            ]
        case .rejected:
            return [
                Strip(
                    id: "revise.rejected", tone: .attention,
                    text: String(
                        localized: "The agent’s answer couldn’t be used. Nothing was changed.",
                        comment: "Notes: strip when the guard rejected the whole answer of the agent"),
                    actions: [tryAgain], isDismissible: true)
            ]
        case .conflict:
            return [
                Strip(
                    id: "revise.conflict", tone: .attention,
                    text: String(
                        localized: "The note changed while the agent was working. Nothing was changed.",
                        comment: "Notes: strip when the note changed under a running agent"), isDismissible: true)
            ]
        case .timedOut:
            return [
                Strip(
                    id: "revise.timedOut", tone: .attention,
                    text: String(
                        localized: "The agent took too long. Nothing was changed.",
                        comment: "Notes: strip when the agent's run hit the time limit"),
                    actions: [tryAgain], isDismissible: true)
            ]
        case .failed:
            return [
                Strip(
                    id: "revise.failed", tone: .error,
                    text: String(
                        localized: "The agent couldn’t finish. Nothing was changed.",
                        comment: "Notes: strip when the agent's run failed"), actions: [tryAgain],
                    isDismissible: true)
            ]
        case .modelBeingRemoved:
            return [
                Strip(
                    id: "revise.removing", tone: .attention,
                    text: String(
                        localized: "The notes model is being removed. Try again in a moment.",
                        comment: "Notes: strip when Models is removing the notes model"), isDismissible: true)
            ]
        case .cancelled, .queued:
            return []
        }
    }

    /// One line per reason: what the user did, and what that left alone.
    private static func skipStrips(_ skipped: [ReviseSkip]) -> [Strip] {
        func count(_ reason: ReviseSkip.Reason) -> Int {
            skipped.filter { $0.reason == reason }.reduce(0) { $0 + $1.threadIDs.count }
        }
        var result: [Strip] = []
        let edited = count(.editedAfterComment)
        if edited > 0 {
            result.append(
                Strip(
                    id: "revise.skipped.edited", tone: .attention,
                    text: String(
                        localized: "You edited \(edited) blocks, so they were not changed.",
                        comment: "Notes: strip listing the comments skipped because their block was edited"),
                    isDismissible: true))
        }
        let changed = count(.textChanged)
        if changed > 0 {
            result.append(
                Strip(
                    id: "revise.skipped.changed", tone: .attention,
                    text: String(
                        localized: "The text of \(changed) comments is gone, so they were not revised.",
                        comment: "Notes: strip listing the comments skipped because their text is not in the note"),
                    isDismissible: true))
        }
        let deferred = count(.deferred)
        if deferred > 0 {
            result.append(
                Strip(
                    id: "revise.skipped.deferred", tone: .attention,
                    text: String(
                        localized: "\(deferred) comments are too much for one run and stay open.",
                        comment: "Notes: strip listing the comments left for the next run"), isDismissible: true))
        }
        return result
    }

    /// Cancel, Try again and the strips' close buttons.
    func performRevise(_ actionID: String) async -> Bool {
        switch actionID {
        case "revise.cancel":
            cancelRevise()
        case "revise.retry":
            await revise()
        default:
            return false
        }
        return true
    }

    func dismissReviseStrip(_ id: String) {
        guard id.hasPrefix("revise.") else { return }
        // The report is one thing: closing any of its strips closes them all.
        currentDocument?.setReviseReport(nil)
    }
}
