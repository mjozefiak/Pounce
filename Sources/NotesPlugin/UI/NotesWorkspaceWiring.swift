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
        makeEditingSession = { content, layerID, document in
            guard let opened = store() else { return nil }
            return NoteEditingSession.make(
                content: content, layerID: layerID, store: opened, registry: registry, model: document,
                readOnly: NotesSettings(settings).readOnly, clock: clock, now: now)
        }
    }
}
