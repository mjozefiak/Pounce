import Foundation
import GRDB
import LintelKit

/// One document that matched `note_fts`.
struct NoteSearchHit: Sendable, Equatable {
    var docID: Int64
    var key: NoteKey
    var layer: String
    var isDetached: Bool
    var startedAtMs: Int64?
    var titleMatched: Bool
    /// Plain text around the first match in the head body; never markup.
    var snippet: String
}

extension NotesStore {
    /// The words of a query as FTS5 prefix terms, folded like the index. `nil` when nothing searchable is left.
    static func matchWords(_ query: String) -> [String]? {
        // Composed first, so a decomposed "ó" is one letter and is not split at its combining mark.
        let folded = NotesFullTextFolding.fold(query.precomposedStringWithCanonicalMapping)
        let words = folded.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        return words.isEmpty ? nil : words
    }

    /// Documents whose title or head body contain every word of the query as a prefix (rowid is `note_doc.id`).
    /// Detached documents are returned too, marked; the caller never merges them into a live note.
    func search(_ query: String, limit: Int = 100) throws -> [NoteSearchHit] {
        guard let words = Self.matchWords(query) else { return [] }
        let terms = words.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
        let all = terms.joined(separator: " ")
        let title = "title : (\(all))"
        return try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT d.id, d.key, d.layer, d.source_state, d.source_started_at_ms, r.body_markdown,
                        d.title_override,
                        d.id IN (SELECT rowid FROM note_fts WHERE note_fts MATCH ?) AS title_hit
                    FROM note_fts JOIN note_doc d ON d.id = note_fts.rowid
                    JOIN note_revision r ON r.id = d.head_revision_id
                    WHERE note_fts MATCH ? ORDER BY d.updated_at DESC, d.id LIMIT ?
                    """,
                arguments: [title, all, limit])
            return rows.compactMap { row -> NoteSearchHit? in
                let rawKey: String = row["key"]
                guard let key = NoteKey(rawValue: rawKey) else { return nil }
                let body: String = row["body_markdown"]
                let state: String? = row["source_state"]
                return NoteSearchHit(
                    docID: row["id"], key: key, layer: row["layer"], isDetached: state == "detached",
                    startedAtMs: row["source_started_at_ms"], titleMatched: row["title_hit"],
                    snippet: Self.snippet(in: body, words: words))
            }
        }
    }

    /// About 80 characters around the first occurrence of a word, compared without case and diacritics and with
    /// the index's folding (`ł` matches `l`), as plain text: Markdown markers are removed.
    static func snippet(in body: String, words: [String]) -> String {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        // The folding replaces one letter by one letter, so offsets in `folded` are offsets in `body`.
        let folded = NotesFullTextFolding.fold(body)
        let hit = words.compactMap { folded.range(of: $0, options: options) }.min { $0.lowerBound < $1.lowerBound }
        let position = hit.map { folded.distance(from: folded.startIndex, to: $0.lowerBound) } ?? 0
        let from = max(0, position - 30)
        let start = body.index(body.startIndex, offsetBy: from, limitedBy: body.endIndex) ?? body.startIndex
        let end = body.index(start, offsetBy: 80, limitedBy: body.endIndex) ?? body.endIndex
        let markers = CharacterSet(charactersIn: "#*_`>|~[]")
        let plain = String(body[start..<end]).unicodeScalars.filter { !markers.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        return plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// One result of a window search after merging the sources' hits with `note_fts`.
struct NoteSearchResult: Sendable, Equatable {
    var id: NoteItemID
    var matches: [NoteLayerMatch]
    var titleMatched: Bool
}

enum NotesSearchMerge {
    /// - Parameters:
    ///   - sourceHits: the sources' summaries that matched (`list(matching:)`).
    ///   - liveOverlayLayers: for each live key, the layers that have a live overlay.
    ///   - ftsHits: `NotesStore.search`.
    /// For a layer with a live overlay only `note_fts` decides: the source's match on it is dropped, and a source
    /// hit left with no layer match and no title match is dropped. A detached hit is never merged into a live
    /// note: it is grouped by `NoteItemID.detached(key, startedAtMs)` (one result with every matched layer).
    static func merge(
        sourceHits: [NoteSummary], liveOverlayLayers: [NoteKey: Set<String>], ftsHits: [NoteSearchHit]
    ) -> [NoteSearchResult] {
        var order: [NoteItemID] = []
        var results: [NoteItemID: NoteSearchResult] = [:]
        func add(_ id: NoteItemID, _ matches: [NoteLayerMatch], title: Bool) {
            if results[id] == nil {
                order.append(id)
                results[id] = NoteSearchResult(id: id, matches: [], titleMatched: false)
            }
            for match in matches where !(results[id]?.matches.contains { $0.layerID == match.layerID } ?? false) {
                results[id]?.matches.append(match)
            }
            if title { results[id]?.titleMatched = true }
        }
        for summary in sourceHits {
            let overlaid = liveOverlayLayers[summary.id] ?? []
            let kept = summary.matches.filter { !overlaid.contains($0.layerID) }
            guard !kept.isEmpty || summary.titleMatched else { continue }
            add(.live(summary.id), kept, title: summary.titleMatched)
        }
        for hit in ftsHits {
            let match = NoteLayerMatch(layerID: hit.layer, snippet: hit.snippet)
            if hit.isDetached {
                add(.detached(hit.key, startedAtMs: hit.startedAtMs ?? 0), [match], title: hit.titleMatched)
            } else {
                add(.live(hit.key), [match], title: hit.titleMatched)
            }
        }
        return order.compactMap { results[$0] }
    }
}
