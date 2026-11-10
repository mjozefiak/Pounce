#if DEBUG
import Foundation
import LintelCore
import LintelKit

extension NotesPlugin {
    /// `plugins.notes.qaComments=threads|popover|changed`: gives the fixture meeting's notes an overlay with two open
    /// comments and a resolved one in the QA run's own store, opens the note in the editor and shows the Comments
    /// tab. Invented text only; a QA aid, not a contract.
    func qaCreateComments(_ mode: String, in model: NotesWorkspaceModel) {
        let storeProvider = storeProvider
        Task { @MainActor in
            guard let store = storeProvider(),
                let source = await model.environment.library.source(for: NotesQAFixtures.meetingID),
                let content = try? await source.content(for: NotesQAFixtures.meetingID),
                let plan = OverlaySeeder.plan(content: content, layerID: "notes"),
                let doc = try? OverlaySeeder.seed(plan, in: store, now: Date().addingTimeInterval(-3600)),
                let head = try? store.headRevision(of: doc.id)
            else { return }
            let now = Date()
            func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
            let text = head.body
            func anchor(_ quote: String) -> CommentAnchor? {
                let range = (text as NSString).range(of: quote)
                return range.location == NSNotFound ? nil : CommentAnchors.make(in: text, range: range)
            }
            if let next = anchor("next sprint") {
                try? store.addThread(
                    docID: doc.id, author: "human", body: "Which sprint? Name it.", anchor: next,
                    anchorRevisionID: head.id, now: ago(4))
            }
            if let owner = anchor("Marek") {
                if let thread = try? store.addThread(
                    docID: doc.id, author: "human", body: "Give the owner.", anchor: owner,
                    anchorRevisionID: head.id, now: ago(3))
                {
                    try? store.addReply(
                        docID: doc.id, threadID: thread, author: "agent", body: "Added the owner to T2.",
                        now: ago(2))
                    try? store.setThreadStatus(docID: doc.id, threadID: thread, status: .resolved, now: ago(2))
                }
            }
            if mode == "changed" {
                let gone = CommentAnchor(
                    start: 0, end: 12, blockHash: "", quote: "a sentence that was deleted", prefix: "", suffix: "")
                try? store.addThread(
                    docID: doc.id, author: "human", body: "Say who decided this.", anchor: gone,
                    anchorRevisionID: head.id, now: ago(1))
            } else if let thu = anchor("Thu") {
                try? store.addThread(
                    docID: doc.id, author: "human", body: "Give the date.", anchor: thu,
                    anchorRevisionID: head.id, now: ago(1))
            }
            await model.refresh()
            model.handle(NoteRoute.route(for: NotesQAFixtures.meetingID))
            let id = NoteItemID.live(NotesQAFixtures.meetingID)
            while model.documents[id]?.phase != .loaded { try? await Task.sleep(for: .milliseconds(50)) }
            model.selectInspectorTab(.comments)
            await model.refreshComments(id)
            model.beginEditing(id)
            if mode == "popover" { model.documents[id]?.qaCommentQuote = "next sprint" }
            if let revise = context.settings.string(NotesSettingsKey.qaRevise) { model.qaRevise(revise, id) }
        }
    }
}

extension NotesWorkspaceModel {
    /// `plugins.notes.qaRevise`: puts the open note's lock in a phase, or shows how a run ended.
    func qaRevise(_ mode: String, _ id: NoteItemID) {
        guard let document = documents[id] else { return }
        let skipped = [ReviseSkip(threadIDs: [1], reason: .editedAfterComment)]
        switch mode {
        case "waiting":
            document.lock.move(to: .flushing)
            document.lock.move(to: .waitingForModel)
        case "writing":
            document.lock.move(to: .flushing)
            document.lock.move(to: .waitingForModel)
            document.lock.move(to: .generating)
        case "done":
            document.setReviseReport(
                .applied(.init(revisionID: 1, blocks: 2, threads: 2, skipped: skipped, rejected: 1)))
        case "skipped": document.setReviseReport(.nothingToRevise(skipped: skipped))
        case "rejected": document.setReviseReport(.rejected)
        case "conflict": document.setReviseReport(.conflict)
        case "timedOut": document.setReviseReport(.timedOut)
        case "needsModel": document.setReviseReport(.needsModel)
        default: break
        }
    }
}
#endif
