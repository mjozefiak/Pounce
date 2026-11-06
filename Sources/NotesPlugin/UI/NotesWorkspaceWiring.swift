import Foundation
import LintelKit

extension NotesWorkspaceModel.Environment {
    /// Connects ⌘N, the title field and the editor to the store: new manual notes (`notes:<uuid>`), titles and one
    /// `NoteEditingSession` per edited layer. Called only when the store may be written (`plugins.notes.readOnly`
    /// is off); without it the section stays read-only. Writes run off the main thread; the store opens on the
    /// first need, never here.
    @MainActor
    mutating func installWriting(
        store: @escaping @MainActor @Sendable () -> NotesStore?, registry: NoteDocumentRegistry,
        settings: PluginSettings, clock: any Clock<Duration>, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        canCreateNotes = true
        canEditNotes = true
        createManualNote = {
            guard let opened = await store() else { return nil }
            return await Task.detached { try? opened.createManualNote(now: now()) }.value
        }
        setTitle = { key, title in
            guard let opened = await store() else { return false }
            return await Task.detached { (try? opened.setTitleOverride(key: key, title: title, now: now())) == true }
                .value
        }
        restoreRevision = { item, layer, revisionID in
            guard let opened = store(), case .live(let key) = item,
                let document = try? opened.liveDocument(key: key, layer: layer)
            else { return .other }
            let writer = registry.writer(for: .live(key, layer: layer), item: item) {
                RevisionWriter(store: opened, target: .existing(docID: document.id), clock: clock, now: now)
            }
            do {
                try await writer.restore(revisionID: revisionID)
                return nil
            } catch NotesError.casConflict {
                return .changed
            } catch NotesError.readOnly, NotesError.schemaNewer {
                return .readOnly
            } catch NotesError.guardRejected(let rule) where rule == "restoreTarget" {
                return .badTarget
            } catch {
                return .other
            }
        }
        let library = self.library
        let budget = contentBudget
        makeEditingSession = { content, layerID, document in
            guard let opened = store() else { return nil }
            let key = content.summary.id
            // The source's current start time, asked before the first seed: a recording recreated since the
            // editor rendered it must not be seeded with the old text.
            let startedAt: @Sendable () async -> Int64? = {
                guard let source = await library.source(for: key) else { return nil }
                let outcome = await SourceFanOut.call(budget: budget, clock: clock) {
                    try await source.content(for: key)
                }
                if case .value(let current?) = outcome { return NoteTime.milliseconds(current.summary.startedAt) }
                return nil
            }
            return NoteEditingSession.make(
                content: content, layerID: layerID, store: opened, registry: registry, model: document,
                readOnly: NotesSettings(settings).readOnly, readOnlyNow: { NotesSettings(settings).readOnly },
                sourceStartedAtMs: startedAt, clock: clock, now: now)
        }
    }
}

extension NotesWorkspaceModel.Environment {
    /// The history of a layer, read from `notes.sqlite` (a detached overlay too, read-only). Opens the store on
    /// the first need; a store that cannot be read is `.failed`, a layer without an overlay is `.none`.
    @MainActor
    mutating func installHistory(store: @escaping @MainActor @Sendable () -> NotesStore?) {
        loadHistory = { item, layer in
            guard let opened = store() else { return .failed }
            return await Task.detached { () -> HistoryState in
                do {
                    let document: DocumentRecord?
                    switch item {
                    case .live(let key): document = try opened.liveDocument(key: key, layer: layer)
                    case .detached(let key, let started):
                        document = try opened.detachedDocuments(key: key, startedAtMs: started).first {
                            $0.layer == layer
                        }
                    }
                    guard let document else { return .none }
                    let revisions = try opened.revisions(of: document.id)
                    return .loaded(
                        HistorySnapshot(
                            docID: document.id, layer: layer, headID: document.headRevisionID, revisions: revisions,
                            isDetached: document.sourceState == .detached))
                } catch {
                    return .failed
                }
            }.value
        }
    }
}
