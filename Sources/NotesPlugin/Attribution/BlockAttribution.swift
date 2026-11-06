import Foundation
import LintelCore
import LintelKit

/// What `note_revision.blocks_json` holds for one block: who wrote it, and the transcript provenance that lets
/// the UI draw a quote chip or keep a speaker (spec "Data Model"). Persisted at write time, never recomputed.
struct StoredBlock: Codable, Equatable, Sendable {
    var author: String
    var quoteTimesMs: [Int]?
    var speakerID: String?
    var startMs: Int?
    var segmentRef: String?

    var hasProvenance: Bool { quoteTimesMs != nil || speakerID != nil || startMs != nil || segmentRef != nil }

    func provenance(blockIndex: Int) -> NoteBlockProvenance? {
        guard hasProvenance else { return nil }
        return NoteBlockProvenance(
            blockIndex: blockIndex, quoteTimesMs: quoteTimesMs ?? [], speakerID: speakerID, startMs: startMs,
            segmentRef: segmentRef)
    }
}

struct StoredBlocks: Codable, Equatable, Sendable {
    var version = 1
    var blocks: [StoredBlock]

    init(blocks: [StoredBlock]) { self.blocks = blocks }

    var json: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String?) -> StoredBlocks? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StoredBlocks.self, from: data)
    }
}

/// Content-addressed attribution (ADR 0008 addendum 0.3): a block's author is the author of the earliest revision
/// of the chain that has an identical block, so edit-and-revert gives the original author back. Pure; the full
/// gutter, legend and chip rules are step 4.3, this is what a write stores.
struct BlockAttribution: Sendable {
    private var firstAuthor: [String: String] = [:]

    init() {}

    /// A chain of applied revisions, oldest first.
    init(chain: [(author: String, body: String)]) {
        for revision in chain { add(author: revision.author, body: revision.body) }
    }

    func author(of block: String) -> String? { firstAuthor[block] }

    mutating func add(author: String, body: String) {
        for block in MarkdownBlocks.split(body) where firstAuthor[block] == nil { firstAuthor[block] = author }
    }

    /// The stored blocks of `body` as the next revision `author` writes it: `author` for a block no earlier
    /// revision has. Provenance is carried from the previous head: by index while the block count is unchanged,
    /// else by identical text (a block edited in the same save as an inserted or removed one loses its reference).
    func stored(
        body: String, author: String, previous: [(text: String, block: StoredBlock)]
    ) -> StoredBlocks {
        let blocks = MarkdownBlocks.split(body)
        var used = Set<Int>()
        let result = blocks.enumerated().map { index, text -> StoredBlock in
            var block = StoredBlock(author: firstAuthor[text] ?? author)
            var source: StoredBlock?
            if previous.count == blocks.count {
                source = previous[index].block
            } else if let match = previous.indices.first(where: { !used.contains($0) && previous[$0].text == text }) {
                used.insert(match)
                source = previous[match].block
            }
            if let source {
                block.quoteTimesMs = source.quoteTimesMs
                block.speakerID = source.speakerID
                block.startMs = source.startMs
                block.segmentRef = source.segmentRef
            }
            return block
        }
        return StoredBlocks(blocks: result)
    }

    /// The seed revision's blocks: the layer's author for every block, the source's provenance by block index.
    static func seeded(layer: NoteLayer) -> StoredBlocks {
        let count = MarkdownBlocks.split(layer.markdown).count
        let byIndex = Dictionary(layer.provenance.map { ($0.blockIndex, $0) }, uniquingKeysWith: { first, _ in first })
        return StoredBlocks(
            blocks: (0..<count).map { index in
                var block = StoredBlock(author: layer.author.rawValue)
                if let provenance = byIndex[index] {
                    block.quoteTimesMs = provenance.quoteTimesMs.isEmpty ? nil : provenance.quoteTimesMs
                    block.speakerID = provenance.speakerID
                    block.startMs = provenance.startMs
                    block.segmentRef = provenance.segmentRef
                }
                return block
            })
    }
}
