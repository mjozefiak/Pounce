import Foundation
import LintelKit

/// The head of one overlaid layer, as the document shows it instead of the source's text.
struct OverlayLayerHead: Sendable, Equatable {
    var layerID: String
    var markdown: String
    var provenance: [NoteBlockProvenance]
    /// The speakers the seed kept (transcript layers); used only when there is no source to ask.
    var seedSpeakers: [NoteSpeaker]
    /// Who wrote each block and which blocks keep their quote chips (step 4.3).
    var attribution: LayerAttribution?
}

/// Puts overlays and sources together for one open note (spec "Components": the document shows the head revision,
/// or the source layer when no overlay exists; a detached item shows only its overlaid layers and never falls back
/// to the source). Pure apart from the store reads in `heads`.
enum NoteOverlayContent {
    /// The heads of the overlaid layers of the note a tab names.
    static func heads(for item: NoteItemID, in store: NotesStore) throws -> [OverlayLayerHead] {
        let documents: [DocumentRecord]
        switch item {
        case .live(let key): documents = try store.liveDocuments(key: key)
        case .detached(let key, let started): documents = try store.detachedDocuments(key: key, startedAtMs: started)
        }
        return try documents.compactMap { document -> OverlayLayerHead? in
            guard let head = try store.headRevision(of: document.id) else { return nil }
            let provenance = (StoredBlocks.decode(head.blocksJSON)?.blocks ?? []).enumerated().compactMap {
                $1.provenance(blockIndex: $0)
            }
            var speakers: [NoteSpeaker] = []
            let chain = try store.revisions(of: document.id)
            if let first = chain.first { speakers = seedSpeakers(first.metaJSON) }
            // The layer's own author is the seed's (an overlay of a manual note is all `human`).
            let layerAuthor = NoteAuthor(rawValue: chain.first?.author ?? NoteAuthor.human.rawValue)
            return OverlayLayerHead(
                layerID: document.layer, markdown: head.body, provenance: provenance, seedSpeakers: speakers,
                attribution: .overlay(
                    layerAuthor: layerAuthor, chain: chain, head: StoredBlocks.decode(head.blocksJSON)))
        }
    }

    private struct SeedMeta: Decodable {
        struct Speaker: Decodable {
            var id: String
            var name: String
            var isSelf: Bool
        }
        var speakers: [Speaker]?
    }

    private static func seedSpeakers(_ json: String?) -> [NoteSpeaker] {
        guard let data = json?.data(using: .utf8), let meta = try? JSONDecoder().decode(SeedMeta.self, from: data)
        else { return [] }
        return (meta.speakers ?? []).map { NoteSpeaker(id: $0.id, name: $0.name, isSelf: $0.isSelf) }
    }

    /// The attribution of every overlaid layer, by layer id; a layer without an overlay is the source's own text.
    static func attributions(heads: [OverlayLayerHead]) -> [String: LayerAttribution] {
        Dictionary(heads.compactMap { head in head.attribution.map { (head.layerID, $0) } }) { first, _ in first }
    }

    /// What the document model gets. `source` is what the source returned (`nil`: gone or never asked).
    static func compose(
        item: NoteItemID, source: NoteContent?, heads: [OverlayLayerHead], summary: NoteSummary?
    ) -> NoteContent? {
        switch item {
        case .live:
            guard var content = source else { return nil }
            for head in heads {
                guard let index = content.layers.firstIndex(where: { $0.id == head.layerID }) else { continue }
                content.layers[index].markdown = head.markdown
                content.layers[index].provenance = head.provenance
            }
            return content
        case .detached(let key, let started):
            guard !heads.isEmpty else { return nil }
            let summary =
                summary
                ?? NoteSummary(id: key, kind: .meeting, startedAt: NoteTime.date(milliseconds: started), state: .ready)
            let layers = heads.sorted { $0.layerID < $1.layerID }.map {
                NoteLayer(
                    id: $0.layerID, author: .human, markdown: $0.markdown, provenance: $0.provenance, version: "")
            }
            return NoteContent(
                summary: summary, layers: layers, speakers: heads.first { !$0.seedSpeakers.isEmpty }?.seedSpeakers ?? []
            )
        }
    }
}
