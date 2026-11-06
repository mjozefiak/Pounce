import Foundation
import GRDB

extension NotesStore {
    /// `notes.sqlite`'s own migrator. Additive only. Once `v1-notes` has merged, a schema change is a new
    /// migration, even before release: GRDB skips a migration by name, so editing this one in place would
    /// leave DEBUG databases behind (spec "Data Model").
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-notes") { db in
            do { try createV1(db) } catch { throw NotesError.migrationFailed(step: "v1-notes") }
        }
        return migrator
    }

    /// `v1-notes`. Its own function so a failing step is reported by its identifier (`migrationFailed`), never
    /// by an SQL message.
    private static func createV1(_ db: Database) throws {
        // No CHECK on `kind`, `layer` or the key prefix: they are validated in Swift, so a third source is
        // not a table rebuild. CHECKs stay only on closed internal states.
        try db.execute(
            sql: """
                CREATE TABLE note_doc (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    key TEXT NOT NULL,
                    layer TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    source_plugin_id TEXT NOT NULL,
                    title_override TEXT,
                    head_revision_id INTEGER NOT NULL,
                    created_at DOUBLE NOT NULL,
                    updated_at DOUBLE NOT NULL,
                    source_state TEXT CHECK (source_state IN ('present', 'detached')),
                    source_started_at_ms INTEGER,
                    source_version_seen TEXT
                );
                CREATE UNIQUE INDEX note_doc_live ON note_doc(key, layer) WHERE source_state IS NOT 'detached';
                CREATE INDEX note_doc_on_key ON note_doc(key);
                CREATE TABLE note_revision (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    doc_id INTEGER NOT NULL REFERENCES note_doc(id) ON DELETE CASCADE,
                    seq INTEGER NOT NULL,
                    author TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('applied', 'proposed', 'discarded')),
                    created_at DOUBLE NOT NULL,
                    summary TEXT,
                    body_markdown TEXT NOT NULL,
                    blocks_json TEXT,
                    meta_json TEXT,
                    UNIQUE (doc_id, seq)
                );
                CREATE TABLE note_comment (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    doc_id INTEGER NOT NULL REFERENCES note_doc(id) ON DELETE CASCADE,
                    thread_id INTEGER NOT NULL,
                    author TEXT NOT NULL,
                    created_at DOUBLE NOT NULL,
                    body TEXT NOT NULL,
                    anchor_revision_id INTEGER NOT NULL REFERENCES note_revision(id),
                    anchor_start INTEGER NOT NULL,
                    anchor_end INTEGER NOT NULL,
                    anchor_block_hash TEXT NOT NULL,
                    anchor_quote TEXT NOT NULL,
                    anchor_prefix TEXT NOT NULL DEFAULT '',
                    anchor_suffix TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved')),
                    resolved_at DOUBLE,
                    CHECK (anchor_end >= anchor_start)
                );
                CREATE INDEX note_comment_on_doc_id ON note_comment(doc_id, thread_id);
                CREATE INDEX note_comment_on_anchor_revision_id ON note_comment(anchor_revision_id);
                """
        )
        // The index reads its text through a view that folds the few letters `remove_diacritics 2` leaves
        // alone (`NotesFullTextFolding`), the way `meeting_fts` does. The folding is FROZEN: the letters are
        // written out by `frozenSQL`, and a test compares them with `NotesFullTextFolding.pairs`. Only the
        // head of an applied revision is indexed; `rowid` is `note_doc.id`, so a hit names its document.
        let title = NotesFullTextFolding.frozenSQL("COALESCE(d.title_override, '')")
        let body = NotesFullTextFolding.frozenSQL("r.body_markdown")
        try db.execute(
            sql: """
                CREATE VIEW note_fts_source AS
                    SELECT d.id AS id, \(title) AS title, \(body) AS body
                    FROM note_doc d JOIN note_revision r ON r.id = d.head_revision_id
                    WHERE r.state = 'applied';
                CREATE VIRTUAL TABLE note_fts USING fts5(
                    title, body, tokenize='unicode61 remove_diacritics 2');
                CREATE TRIGGER note_fts_doc_au AFTER UPDATE OF head_revision_id, title_override ON note_doc BEGIN
                    DELETE FROM note_fts WHERE rowid = new.id;
                    INSERT INTO note_fts(rowid, title, body)
                        SELECT id, title, body FROM note_fts_source WHERE id = new.id;
                END;
                CREATE TRIGGER note_fts_doc_ad AFTER DELETE ON note_doc BEGIN
                    DELETE FROM note_fts WHERE rowid = old.id;
                END;
                CREATE TRIGGER note_fts_revision_au AFTER UPDATE OF body_markdown, state ON note_revision BEGIN
                    DELETE FROM note_fts WHERE rowid IN (SELECT id FROM note_doc WHERE head_revision_id = new.id);
                    INSERT INTO note_fts(rowid, title, body)
                        SELECT s.id, s.title, s.body FROM note_fts_source s
                        JOIN note_doc d ON d.id = s.id WHERE d.head_revision_id = new.id;
                END;
                """
        )
    }
}
