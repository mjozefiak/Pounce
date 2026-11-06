import Foundation
import LintelKit

/// What the section shows as a whole (prototype `lib-empty`, `lib-off`, `lib-noresults`, `lib-locked`,
/// `lib-loading`) and the strips and the status line that say what is true of the open note (`lib-interrupted`,
/// `lib-needsmodel`, `lib-regen`, `lib-saveerror`). Everything here is derived from the model's state, so it is
/// tested without a window. Text never contains a note's words except the user's own query.
extension NotesWorkspaceModel {
    enum Screen: Equatable {
        /// Nothing read yet.
        case loading
        /// `notes.sqlite` cannot be read and there is nothing from the sources to show.
        case locked
        /// No notes at all; `recordingOff` when neither Meetings nor Dictation is on.
        case empty(recordingOff: Bool)
        /// A search that found nothing; carries what the user typed.
        case noResults(String)
        case list
    }

    var screen: Screen {
        if loadState == .loading { return .loading }
        if !overlaysAvailable && rows.isEmpty { return .locked }
        if rows.isEmpty {
            if let query = searchQuery { return .noResults(query.raw) }
            if unavailable.isEmpty { return .empty(recordingOff: recordingOff) }
        }
        return .list
    }

    /// Neither recording plugin is active (Notes itself stays available).
    var recordingOff: Bool {
        loadState == .loaded && activePlugins.isDisjoint(with: environment.recordingPluginIDs)
    }

    // MARK: Status bar

    struct StatusLine: Equatable {
        enum Kind: Equatable {
            case ok, attention, error, muted
            /// Work is going on; `progress` is 0...1 when it is known.
            case busy(progress: Double?)
        }
        var kind: Kind
        var text: String
    }

    /// The left part of the status bar before "Encrypted on this Mac" (`nil` when there is nothing to say).
    var statusLine: StatusLine? {
        switch screen {
        case .loading:
            return StatusLine(
                kind: .busy(progress: nil),
                text: String(localized: "Opening notes…", comment: "Notes status bar while the list is read"))
        case .locked:
            return StatusLine(
                kind: .error,
                text: String(localized: "Key unavailable", comment: "Notes status bar: the key to the notes is missing")
            )
        default: break
        }
        if !overlaysAvailable {
            return StatusLine(
                kind: .error,
                text: String(localized: "Key unavailable", comment: "Notes status bar: the key to the notes is missing")
            )
        }
        switch currentState {
        case .writing(let done, let of)?:
            return StatusLine(
                kind: .busy(progress: of > 0 ? min(1, max(0, Double(done) / Double(of))) : nil),
                text: String(
                    localized: "Writing notes \(done)/\(of)",
                    comment: "Notes status bar while the open note's notes are written"))
        case .needsModel?:
            return StatusLine(
                kind: .attention,
                text: String(
                    localized: "Notes model not installed", comment: "Notes status bar: the notes model is missing"))
        default: break
        }
        if case .empty(let off) = screen {
            return off
                ? StatusLine(
                    kind: .muted,
                    text: String(
                        localized: "Recording off", comment: "Notes status bar: Meetings and Dictation are off"))
                : StatusLine(kind: .ok, text: String(localized: "Ready", comment: "Notes status bar: nothing to do"))
        }
        if recordingOff {
            return StatusLine(
                kind: .muted,
                text: String(localized: "Recording off", comment: "Notes status bar: Meetings and Dictation are off"))
        }
        return nil
    }

    /// Whether "Encrypted on this Mac" is shown (not while loading or locked, like the prototype).
    var showsEncryptionNote: Bool {
        switch screen {
        case .loading, .locked: false
        default: true
        }
    }

    /// The right part of the status bar: "27 notes · 1 writing", empty while loading or locked.
    var statusRight: String {
        switch screen {
        case .loading, .locked: ""
        default: statusSummary
        }
    }

    /// The state of the open note, from the content when it is read, else from its row.
    var currentState: NoteState? {
        guard let id = currentID else { return nil }
        return documents[id]?.state ?? row(for: id)?.summary.state
    }

    // MARK: Strips

    struct Strip: Identifiable, Equatable {
        enum Tone: Equatable {
            case accent, attention, error
        }
        struct Action: Identifiable, Equatable {
            var id: String
            var title: String
        }
        var id: String
        var tone: Tone
        var text: String
        var actions: [Action] = []
        var isDismissible = false
    }

    /// The strips under the path bar, most important first.
    var strips: [Strip] {
        var result: [Strip] = []
        if !overlaysAvailable && !rows.isEmpty {
            result.append(
                Strip(
                    id: "locked", tone: .error,
                    text: String(
                        localized: "Lintel can’t read the key to your notes. Nothing was deleted.",
                        comment: "Notes: strip when the key to notes.sqlite cannot be read"),
                    actions: [Strip.Action(id: "locked.retry", title: Self.tryAgain)]))
        }
        if feedback == .saveFailed {
            result.append(
                Strip(
                    id: "save", tone: .error, text: NotePathBar.text(.saveFailed),
                    actions: [
                        Strip.Action(id: "save.retry", title: Self.tryAgain),
                        Strip.Action(
                            id: "save.other",
                            title: String(
                                localized: "Choose another place…",
                                comment: "Notes: saves the Markdown file somewhere else")),
                    ], isDismissible: true))
        }
        for failed in [
            Feedback.restoreFailed, .restoreChanged, .restoreReadOnly, .restoreTargetInvalid, .deleteFailed,
            .copyNotRemoved, .commentFailed, .commentReadOnly, .commentChanged,
        ] where feedback == failed {
            result.append(
                Strip(
                    id: "feedback", tone: failed == .copyNotRemoved ? .attention : .error,
                    text: NotePathBar.text(failed), isDismissible: true))
        }
        if let document = currentDocument, document.phase == .loaded {
            if document.session?.keptAsProposal == true {
                result.append(
                    Strip(
                        id: "proposal", tone: .attention,
                        text: String(
                            localized: "Your edits were kept as a proposal.",
                            comment:
                                "Notes: strip after the note changed under the editor and the typed text was set aside"),
                        actions: [
                            Strip.Action(
                                id: "proposal.compare",
                                title: String(
                                    localized: "Compare", comment: "Notes: opens the comparison of two versions"))
                        ]))
            }
            if document.session?.saveFailed == true {
                result.append(
                    Strip(
                        id: "edit.save", tone: .error,
                        text: String(
                            localized: "Your last change couldn’t be saved. The text is kept and saved again.",
                            comment: "Notes: strip when the editor's text could not be written"),
                        actions: [Strip.Action(id: "edit.save.retry", title: Self.tryAgain)]))
            }
            result.append(contentsOf: stateStrips(for: document))
            result.append(contentsOf: reviseStrips(for: document))
        }
        return result
    }

    private static var tryAgain: String {
        String(localized: "Try again", comment: "Notes: saves the Markdown file again")
    }

    private func stateStrips(for document: NoteDocumentModel) -> [Strip] {
        var result: [Strip] = []
        let sourceActions = document.actions.map {
            Strip.Action(id: "doc.\($0.id)", title: String(localized: $0.title))
        }
        switch document.state {
        case .interrupted?:
            result.append(
                Strip(
                    id: "interrupted", tone: .attention,
                    text: String(
                        localized: "This meeting was interrupted. Lintel can transcribe the part it recorded.",
                        comment: "Notes: strip on an interrupted meeting"), actions: sourceActions))
        case .needsModel?:
            result.append(
                Strip(
                    id: "needsModel", tone: .attention,
                    text: String(
                        localized: "Notes need a model. It downloads once and runs on this Mac.",
                        comment: "Notes: strip when the notes model is missing"),
                    actions: [
                        Strip.Action(
                            id: "models.open",
                            title: String(localized: "Open Models", comment: "Notes: opens the Models pane"))
                    ]))
        case .writing(let done, let of)?:
            result.append(
                Strip(
                    id: "writing", tone: .accent,
                    text: String(
                        localized: "Agent is writing notes · \(done) of \(of) · read-only until it finishes",
                        comment: "Notes: strip while the notes of the open note are written"),
                    actions: sourceActions))
        default: break
        }
        if document.actionFailed {
            result.append(
                Strip(
                    id: "actionFailed", tone: .error,
                    text: String(
                        localized: "That didn’t finish. Nothing was changed.",
                        comment: "Notes: strip when an action of the source failed"), isDismissible: true))
        }
        return result
    }

    /// A strip's action button or its close button.
    func perform(_ actionID: String) async {
        switch actionID {
        case "locked.retry": await refresh()
        case "save.retry": await saveMarkdown(retry: true)
        case "save.other": await saveMarkdown()
        case "models.open": environment.openModels()
        case "edit.save.retry": await currentDocument?.session?.retry()
        case "proposal.compare": await showProposalCompare()
        case "revise.cancel", "revise.retry": _ = await performRevise(actionID)
        default:
            guard actionID.hasPrefix("doc."), let id = currentID, let document = documents[id] else { return }
            let name = String(actionID.dropFirst(4))
            guard let action = document.actions.first(where: { $0.id == name }) else { return }
            document.actionFailed = false
            do {
                try await action.perform()
                await loadContent(id)
            } catch {
                document.actionFailed = true
            }
        }
    }

    func dismissStrip(_ id: String) {
        switch id {
        case "save", "feedback": dismissFeedback()
        case "actionFailed": currentDocument?.actionFailed = false
        default: dismissReviseStrip(id)
        }
    }
}
