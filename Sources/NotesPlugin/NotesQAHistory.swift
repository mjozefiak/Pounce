#if DEBUG
import Foundation
import LintelCore
import LintelKit

extension NotesPlugin {
    /// `plugins.notes.qaHistory=history|compare`: gives the fixture meeting's notes a history in the QA run's own
    /// store (the agent's seed, then two edits of yours) and opens the note with the History tab, `compare` with
    /// the comparison of the last edit. Invented text only; a QA aid, not a contract.
    func qaCreateHistory(_ mode: String, in model: NotesWorkspaceModel) {
        let storeProvider = storeProvider
        Task { @MainActor in
            // The content comes from the fixture source the list reads, so the start time is the one it reports.
            guard let store = storeProvider(),
                let source = await model.environment.library.source(for: NotesQAFixtures.meetingID),
                let content = try? await source.content(for: NotesQAFixtures.meetingID),
                let plan = OverlaySeeder.plan(content: content, layerID: "notes")
            else { return }
            let now = Date()
            func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
            guard let doc = try? OverlaySeeder.seed(plan, in: store, now: ago(11)) else { return }
            let seedBody = plan.snapshot.markdown
            var attribution = BlockAttribution(chain: [(plan.snapshot.author.rawValue, seedBody)])
            var previous = Array(
                zip(MarkdownBlocks.split(seedBody), BlockAttribution.seeded(layer: plan.snapshot).blocks)
            ).map { (text: $0, block: $1) }
            var head = (try? store.headRevision(of: doc.id))?.id
            let edited =
                seedBody
                .replacingOccurrences(
                    of: "Pricing page moves to the next sprint (Marek confirmed).",
                    with: "Pricing page moves to the next sprint (Marek confirmed on Thursday).")
            let steps: [(author: String, minutes: Double, body: String)] = [
                ("human", 5, edited),
                ("human", 1, edited + "\n\n- Ask legal about the pricing copy"),
            ]
            for step in steps {
                let stored = attribution.stored(body: step.body, author: step.author, previous: previous)
                head = try? store.appendRevision(
                    NewNoteRevision(
                        docID: doc.id, author: step.author, state: .applied, body: step.body,
                        blocksJSON: stored.json, now: ago(step.minutes), expectedHeadID: head))
                attribution.add(author: step.author, body: step.body)
                previous = Array(zip(MarkdownBlocks.split(step.body), stored.blocks)).map { (text: $0, block: $1) }
            }
            await model.refresh()
            model.handle(NoteRoute.route(for: NotesQAFixtures.meetingID))
            let id = NoteItemID.live(NotesQAFixtures.meetingID)
            // The document's own view reads the note too; the newest read wins, so wait for it (QA only).
            while model.documents[id]?.phase != .loaded { try? await Task.sleep(for: .milliseconds(50)) }
            model.selectInspectorTab(.history)
            await model.loadHistory(for: id)
            if mode == "compare", case .loaded(let snapshot)? = model.documents[id]?.history,
                let last = snapshot.entries.first
            {
                await model.showCompare(revisionID: last.id)
            }
        }
    }
}
#endif

#if DEBUG
extension NotesPlugin {
    /// `plugins.notes.qaDelete=meeting|dictation|manual|copy`: opens that delete confirmation (fixture notes, the
    /// QA run's own store). Confirming deletes only the fixture; nothing real is reachable in QA mode.
    func qaRequestDelete(_ mode: String, in model: NotesWorkspaceModel) {
        let storeProvider = storeProvider
        Task { @MainActor in
            await model.refresh()
            let request: NotesWorkspaceModel.DeleteRequest
            switch mode {
            case "dictation":
                request = .init(
                    id: .live(NotesQAFixtures.dictationID), title: "Hi Kasia, I moved the review to Thursday at 10.",
                    subject: .dictation, hasEdits: false)
            case "manual":
                guard let store = storeProvider(), let key = try? store.createManualNote(now: Date()) else { return }
                _ = try? store.setTitleOverride(key: key, title: "Release checklist", now: Date())
                await model.refresh()
                request = .init(id: .live(key), title: "Release checklist", subject: .manual, hasEdits: true)
            case "copy":
                request = .init(
                    id: .detached(NotesQAFixtures.meetingID, startedAtMs: 0), title: "Orchard weekly sync",
                    subject: .copy, hasEdits: true)
            default:
                request = .init(
                    id: .live(NotesQAFixtures.meetingID), title: "Orchard weekly sync", subject: .meeting,
                    hasEdits: mode == "meeting-edited")
            }
            model.pendingDelete = request
        }
    }
}
#endif
