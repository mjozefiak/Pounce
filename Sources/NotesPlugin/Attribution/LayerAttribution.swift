import Foundation
import LintelCore
import LintelKit

/// A note on a block that is not an untouched block of the recording's own notes (spec "Attribution and
/// verification invariant"): shown, not hidden.
enum BlockMark: Equatable, Sendable {
    /// An `agent` block that is not the seeded block: revised by the agent, not checked against the recording.
    case revisedNotChecked
    /// A `human` block.
    case addedByYou
}

/// What the gutter and the block draw for one block: the author bar, the mark and whether quote chips may show.
struct BlockAttributionInfo: Equatable, Sendable {
    var index: Int
    var author: NoteAuthor
    var mark: BlockMark?
    /// `false` once the block lost its right to a quote chip (revised or written after the seed).
    var showsQuotes: Bool
}

/// The attribution of one layer's head, ready to draw (spec step 4.3). Pure.
///
/// - **Authors** are content-addressed (`BlockAttribution`): a block's author is the author of the earliest
///   applied revision with an identical block. The head's stored authors (`blocks_json`) are used when present,
///   so a Restore, which keeps authors, draws what was written.
/// - **Chips** (spec): for a layer written by the agent, a block keeps its quote chips only when its text equals a
///   block of the seed `agent` revision stored in `notes.sqlite`, never when it merely equals the live source. A
///   revision the SOURCE wrote for the layer (a regenerate appended by reconciliation, marked `source_version`)
///   counts as a seed: the source verified its quotes against the recording itself. A block the agent revised or a
///   human wrote or edited is marked and loses its chips unless its text equals a seeded block.
/// - A layer that is not the agent's (a transcript, the original speech) has no verification promise: bars only.
/// - A layer without an overlay is the source's own text: every block is the layer's author, untouched.
struct LayerAttribution: Equatable, Sendable {
    var layerAuthor: NoteAuthor
    /// Block text to the first author of that text in the chain.
    var firstAuthors: [String: String]
    /// The authors the head stored, by block index; `nil` when it stored none (then `firstAuthors` decides).
    var storedAuthors: [String]?
    /// The texts of the seed (and source-written) blocks; `nil` for a layer without an overlay.
    var seededTexts: Set<String>?

    /// A layer without an overlay: the source's text, untouched.
    static func source(author: NoteAuthor) -> LayerAttribution {
        LayerAttribution(layerAuthor: author, firstAuthors: [:], storedAuthors: nil, seededTexts: nil)
    }

    /// The layer as the editor renders it, before any overlay exists: the first keystroke seeds exactly this, so
    /// its blocks are the seed's and whatever is typed on top is `human`.
    static func seeding(layer: NoteLayer) -> LayerAttribution {
        var attribution = BlockAttribution()
        attribution.add(author: layer.author.rawValue, body: layer.markdown)
        return LayerAttribution(
            layerAuthor: layer.author, firstAuthors: attribution.authors, storedAuthors: nil,
            seededTexts: Set(MarkdownBlocks.split(layer.markdown)))
    }

    /// From the applied chain of an overlay, oldest first, and the head's stored blocks.
    static func overlay(
        layerAuthor: NoteAuthor, chain: [RevisionRecord], head: StoredBlocks?
    ) -> LayerAttribution {
        let applied = chain.filter { $0.state == .applied }.sorted { $0.seq < $1.seq }
        let attribution = BlockAttribution(chain: applied.map { ($0.author, $0.body) })
        var seeded = Set<String>()
        for (offset, revision) in applied.enumerated()
        where revision.author == layerAuthor.rawValue && (offset == 0 || Self.isSourceRevision(revision)) {
            seeded.formUnion(MarkdownBlocks.split(revision.body))
        }
        return LayerAttribution(
            layerAuthor: layerAuthor, firstAuthors: attribution.authors, storedAuthors: head?.blocks.map(\.author),
            seededTexts: seeded)
    }

    /// A revision the source made for this layer: reconciliation marks it with `source_version`.
    private static func isSourceRevision(_ revision: RevisionRecord) -> Bool {
        guard let data = revision.metaJSON?.data(using: .utf8),
            let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return meta["source_version"] != nil
    }

    /// The description of each block of `blocks` (the text split by `MarkdownBlocks.split`). `useStored` is true
    /// for the head as written (the stored authors line up with its blocks), false while typing (a new or edited
    /// block is not in the chain yet, so it is `human`).
    func infos(blocks: [String], useStored: Bool = true) -> [BlockAttributionInfo] {
        let stored = useStored && storedAuthors?.count == blocks.count ? storedAuthors : nil
        return blocks.enumerated().map { index, text in
            let unwritten = seededTexts == nil ? layerAuthor.rawValue : NoteAuthor.human.rawValue
            let author = NoteAuthor(rawValue: stored?[index] ?? firstAuthors[text] ?? unwritten)
            guard let seeded = seededTexts, layerAuthor == .agent else {
                return BlockAttributionInfo(index: index, author: author, mark: nil, showsQuotes: true)
            }
            if seeded.contains(text) {
                return BlockAttributionInfo(index: index, author: author, mark: nil, showsQuotes: true)
            }
            let mark: BlockMark? =
                author == .human ? .addedByYou : author == .agent ? .revisedNotChecked : nil
            return BlockAttributionInfo(index: index, author: author, mark: mark, showsQuotes: false)
        }
    }
}
