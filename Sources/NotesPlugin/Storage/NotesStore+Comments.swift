import Foundation
import GRDB
import LintelCore

/// `note_comment.status`.
enum CommentStatus: String, Sendable, CaseIterable {
    case open
    case resolved
}

/// One `note_comment` row: a comment, or a reply (it repeats its thread's anchor and status). Holds the words of
/// other people: never logged.
struct CommentRecord: Sendable, Equatable, Identifiable {
    var id: Int64
    var docID: Int64
    var threadID: Int64
    var author: String
    var createdAt: Date
    var body: String
    var anchorRevisionID: Int64
    var anchor: CommentAnchor
    var status: CommentStatus
    var resolvedAt: Date?
}

extension NotesStore {
    /// A comment is at most this long.
    static let commentLimit = 4000

    private static let commentColumns = """
        id, doc_id, thread_id, author, created_at, body, anchor_revision_id, anchor_start, anchor_end,
        anchor_block_hash, anchor_quote, anchor_prefix, anchor_suffix, status, resolved_at
        """

    private static func commentRecord(_ row: Row) -> CommentRecord? {
        guard let status = CommentStatus(rawValue: row["status"]) else { return nil }
        let resolvedAt: Double? = row["resolved_at"]
        return CommentRecord(
            id: row["id"], docID: row["doc_id"], threadID: row["thread_id"], author: row["author"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]), body: row["body"],
            anchorRevisionID: row["anchor_revision_id"],
            anchor: CommentAnchor(
                start: row["anchor_start"], end: row["anchor_end"], blockHash: row["anchor_block_hash"],
                quote: row["anchor_quote"], prefix: row["anchor_prefix"], suffix: row["anchor_suffix"]),
            status: status, resolvedAt: resolvedAt.map(Date.init(timeIntervalSince1970:)))
    }

    /// A comment as it is stored: bidi and control characters stripped, trimmed, at most `commentLimit` characters;
    /// `nil` when nothing is left.
    static func cleanComment(_ body: String) -> String? {
        let clean = MarkdownText.strippingBidiAndControls(body).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return String(clean.prefix(commentLimit))
    }

    // MARK: Reads

    /// Every comment of a document, threads in the order they were started, replies after their comment.
    func comments(of docID: Int64) throws -> [CommentRecord] {
        try read { db in
            try Row.fetchAll(
                db, sql: "SELECT \(Self.commentColumns) FROM note_comment WHERE doc_id = ? ORDER BY thread_id, id",
                arguments: [docID]
            ).compactMap(Self.commentRecord)
        }
    }

    /// How many threads of a document are open (the number on the Comments tab and on "Revise with N comments").
    func openThreadCount(of docID: Int64) throws -> Int {
        try read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT count(DISTINCT thread_id) FROM note_comment WHERE doc_id = ? AND status = 'open'
                    """, arguments: [docID]) ?? 0
        }
    }

    // MARK: Writes (refused with `plugins.notes.readOnly` and a newer schema, like every content write)

    /// Starts a thread: the first comment, anchored to `anchorRevisionID`. Returns its thread id.
    @discardableResult
    func addThread(
        docID: Int64, author: String, body: String, anchor: CommentAnchor, anchorRevisionID: Int64, now: Date
    ) throws -> Int64 {
        guard let clean = Self.cleanComment(body) else { throw NotesError.guardRejected(rule: "emptyComment") }
        return try write { db in
            let thread =
                (try Int64.fetchOne(
                    db, sql: "SELECT COALESCE(MAX(thread_id), 0) FROM note_comment WHERE doc_id = ?",
                    arguments: [docID]) ?? 0) + 1
            try Self.insertComment(
                docID: docID, threadID: thread, author: author, body: clean, anchor: anchor,
                anchorRevisionID: anchorRevisionID, status: .open, resolvedAt: nil, now: now, in: db)
            return thread
        }
    }

    /// A reply: it repeats the anchor and the status of the thread's first comment. `false` when there is no such
    /// thread.
    @discardableResult
    func addReply(docID: Int64, threadID: Int64, author: String, body: String, now: Date) throws -> Bool {
        guard let clean = Self.cleanComment(body) else { throw NotesError.guardRejected(rule: "emptyComment") }
        return try write { db in
            guard
                let root = try Row.fetchOne(
                    db,
                    sql:
                        "SELECT \(Self.commentColumns) FROM note_comment WHERE doc_id = ? AND thread_id = ? ORDER BY id LIMIT 1",
                    arguments: [docID, threadID]
                ).flatMap(Self.commentRecord)
            else { return false }
            try Self.insertComment(
                docID: docID, threadID: threadID, author: author, body: clean, anchor: root.anchor,
                anchorRevisionID: root.anchorRevisionID, status: root.status, resolvedAt: root.resolvedAt, now: now,
                in: db)
            return true
        }
    }

    private static func insertComment(
        docID: Int64, threadID: Int64, author: String, body: String, anchor: CommentAnchor, anchorRevisionID: Int64,
        status: CommentStatus, resolvedAt: Date?, now: Date, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO note_comment (doc_id, thread_id, author, created_at, body, anchor_revision_id,
                    anchor_start, anchor_end, anchor_block_hash, anchor_quote, anchor_prefix, anchor_suffix, status,
                    resolved_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                docID, threadID, author, now.timeIntervalSince1970, body, anchorRevisionID, anchor.start, anchor.end,
                anchor.blockHash, anchor.quote, anchor.prefix, anchor.suffix, status.rawValue,
                resolvedAt?.timeIntervalSince1970,
            ])
    }

    /// Resolves or reopens a whole thread. `false` when there is no such thread.
    @discardableResult
    func setThreadStatus(docID: Int64, threadID: Int64, status: CommentStatus, now: Date) throws -> Bool {
        try write { db in
            try db.execute(
                sql: """
                    UPDATE note_comment SET status = ?, resolved_at = ? WHERE doc_id = ? AND thread_id = ?
                    """,
                arguments: [
                    status.rawValue, status == .resolved ? now.timeIntervalSince1970 : nil, docID, threadID,
                ])
            return db.changesCount > 0
        }
    }

    /// Points a whole thread at new text of the head revision (the user selected it after "text changed").
    @discardableResult
    func reanchorThread(docID: Int64, threadID: Int64, anchor: CommentAnchor, anchorRevisionID: Int64) throws -> Bool {
        try write { db in
            try db.execute(
                sql: """
                    UPDATE note_comment SET anchor_revision_id = ?, anchor_start = ?, anchor_end = ?,
                        anchor_block_hash = ?, anchor_quote = ?, anchor_prefix = ?, anchor_suffix = ?
                    WHERE doc_id = ? AND thread_id = ?
                    """,
                arguments: [
                    anchorRevisionID, anchor.start, anchor.end, anchor.blockHash, anchor.quote, anchor.prefix,
                    anchor.suffix, docID, threadID,
                ])
            return db.changesCount > 0
        }
    }
}
