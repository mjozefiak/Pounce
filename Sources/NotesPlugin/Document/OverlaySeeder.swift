import Foundation
import LintelKit

/// Everything a first write needs about the layer the editor rendered: the layer as it was on screen (text and
/// `version`), when the recording started, and the speakers at that moment. Built from the content the editor
/// showed, never re-read from the source: a source change between render and first write cannot change the seed.
struct SeedPlan: Sendable, Equatable {
    var key: NoteKey
    var layerID: String
    var kind: NoteKind
    var pluginID: PluginID
    var startedAtMs: Int64
    var snapshot: NoteLayer
    var speakers: [NoteSpeaker]
}

/// Per-layer seeding (spec "Saving", "Not before the source is ready"). The first time the user edits, comments on
/// or asks the agent about a layer, Notes creates a document row seeded with that layer's text only; a layer
/// without an overlay always shows the source's current text.
enum OverlaySeeder {
    /// Seeding is allowed in `.ready`, `.partial`, `.stale`, `.failed`, `.needsModel` and `.interrupted`, and only
    /// with text for that layer; never while recording, processing or writing.
    static func canSeed(state: NoteState, layer: NoteLayer) -> Bool {
        guard !layer.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch state {
        case .ready, .partial, .stale, .failed, .needsModel, .interrupted: return true
        case .recording, .processing, .writing: return false
        }
    }

    /// The plan for a layer of a recorded note, or `nil` when the layer cannot be seeded now.
    static func plan(content: NoteContent, layerID: String) -> SeedPlan? {
        guard let layer = content.layers.first(where: { $0.id == layerID }),
            canSeed(state: content.summary.state, layer: layer)
        else { return nil }
        let key = content.summary.id
        return SeedPlan(
            key: key, layerID: layerID, kind: content.summary.kind, pluginID: key.pluginID,
            startedAtMs: NoteTime.milliseconds(content.summary.startedAt), snapshot: layer, speakers: content.speakers)
    }

    /// The seed revision's row: the layer's own author and text, `source_version_seen` = the rendered version,
    /// `source_started_at_ms` rounded the way detaching compares it. A transcript seed keeps a speakers snapshot.
    static func document(for plan: SeedPlan, now: Date) -> NewNoteDocument {
        NewNoteDocument(
            key: plan.key, layer: plan.layerID, kind: plan.kind, sourcePluginID: plan.pluginID, titleOverride: nil,
            sourceState: .present, sourceStartedAtMs: plan.startedAtMs, sourceVersionSeen: plan.snapshot.version,
            author: plan.snapshot.author.rawValue, body: plan.snapshot.markdown, summary: nil,
            blocksJSON: BlockAttribution.seeded(layer: plan.snapshot).json, metaJSON: meta(for: plan), now: now)
    }

    private struct SeedMeta: Encodable {
        struct Speaker: Encodable {
            var id: String
            var name: String
            var isSelf: Bool
        }
        var seed = true
        var speakers: [Speaker]?
    }

    private static func meta(for plan: SeedPlan) -> String? {
        let speakers =
            plan.layerID == "transcript"
            ? plan.speakers.map { SeedMeta.Speaker(id: $0.id, name: $0.name, isSelf: $0.isSelf) } : nil
        guard let data = try? JSONEncoder().encode(SeedMeta(speakers: speakers)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A seed on its own (a comment without editing, a question to the agent): the document with only its seed
    /// revision. Returns the live document that already exists for the layer, if any.
    @discardableResult
    static func seed(_ plan: SeedPlan, in store: NotesStore, now: Date) throws -> DocumentRecord {
        if let existing = try store.liveDocument(key: plan.key, layer: plan.layerID) { return existing }
        let created = try store.insertDocument(document(for: plan, now: now))
        guard let record = try store.document(id: created.docID) else { throw NotesError.storeClosed }
        return record
    }
}
