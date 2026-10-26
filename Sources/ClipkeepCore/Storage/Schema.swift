public enum Schema {
    public static let latestVersion = 6
    public static let migrations = [version1, version2, version3, version4, version5, version6]
    public static let migrator = Migrator(migrations: migrations)

    private static let version1 = Migration(
        version: 1,
        statements: [
            """
            CREATE TABLE contents (
                id INTEGER PRIMARY KEY,
                hash TEXT NOT NULL UNIQUE,
                normalized_hash TEXT NOT NULL,
                text TEXT NOT NULL,
                kind TEXT NOT NULL DEFAULT 'text',
                first_seen_at REAL NOT NULL
            )
            """,
            "CREATE INDEX contents_normalized_hash ON contents(normalized_hash)",
            """
            CREATE TABLE topics (
                id INTEGER PRIMARY KEY,
                label TEXT NOT NULL,
                created_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE sessions (
                id INTEGER PRIMARY KEY,
                started_at REAL NOT NULL,
                ended_at REAL NOT NULL,
                topic_id INTEGER REFERENCES topics(id) ON DELETE SET NULL
            )
            """,
            """
            CREATE TABLE copy_events (
                id INTEGER PRIMARY KEY,
                content_id INTEGER NOT NULL REFERENCES contents(id) ON DELETE CASCADE,
                copied_at REAL NOT NULL,
                app_bundle_id TEXT,
                app_name TEXT,
                window_title TEXT,
                url TEXT,
                session_id INTEGER REFERENCES sessions(id) ON DELETE SET NULL
            )
            """,
            "CREATE INDEX copy_events_content_id ON copy_events(content_id)",
            "CREATE INDEX copy_events_copied_at ON copy_events(copied_at)",
            """
            CREATE TABLE entities (
                id INTEGER PRIMARY KEY,
                content_id INTEGER NOT NULL REFERENCES contents(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                value TEXT NOT NULL,
                UNIQUE (content_id, kind, value)
            )
            """,
            "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        ])

    /// Search support: a folded copy of the text, the time of the latest copy (so listing and
    /// ranking never scan `copy_events`), and a trigram full-text index over the folded text.
    /// The trigram tokenizer matches substrings and ignores case; queries need three characters.
    /// `search_text` is filled by `SearchText.fold`; the backfill below is ASCII-only and exists
    /// for databases created before this version.
    private static let version2 = Migration(
        version: 2,
        statements: [
            "ALTER TABLE contents ADD COLUMN search_text TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE contents ADD COLUMN last_copied_at REAL NOT NULL DEFAULT 0",
            """
            UPDATE contents SET
                search_text = lower(text),
                last_copied_at = COALESCE(
                    (SELECT max(copied_at) FROM copy_events WHERE content_id = contents.id),
                    first_seen_at)
            """,
            "CREATE INDEX contents_last_copied_at ON contents(last_copied_at DESC, id DESC)",
            """
            CREATE TRIGGER copy_events_touch_content AFTER INSERT ON copy_events BEGIN
                UPDATE contents SET last_copied_at = max(last_copied_at, new.copied_at)
                WHERE id = new.content_id;
            END
            """,
            """
            CREATE VIRTUAL TABLE contents_fts USING fts5(
                search_text, content='contents', content_rowid='id', tokenize='trigram'
            )
            """,
            """
            CREATE TRIGGER contents_fts_insert AFTER INSERT ON contents BEGIN
                INSERT INTO contents_fts(rowid, search_text) VALUES (new.id, new.search_text);
            END
            """,
            """
            CREATE TRIGGER contents_fts_delete AFTER DELETE ON contents BEGIN
                INSERT INTO contents_fts(contents_fts, rowid, search_text)
                VALUES ('delete', old.id, old.search_text);
            END
            """,
            """
            CREATE TRIGGER contents_fts_update AFTER UPDATE OF id, search_text ON contents BEGIN
                INSERT INTO contents_fts(contents_fts, rowid, search_text)
                VALUES ('delete', old.id, old.search_text);
                INSERT INTO contents_fts(rowid, search_text) VALUES (new.id, new.search_text);
            END
            """,
            "INSERT INTO contents_fts(contents_fts) VALUES ('rebuild')",
        ])

    /// Duplicate detection: a SimHash fingerprint per content, a band index that finds candidates
    /// without scanning every row, and links between related contents. Nothing is merged or
    /// overwritten; a link only records that two stored texts belong together.
    private static let version3 = Migration(
        version: 3,
        statements: [
            "ALTER TABLE contents ADD COLUMN simhash INTEGER",
            """
            CREATE TABLE content_bands (
                content_id INTEGER NOT NULL REFERENCES contents(id) ON DELETE CASCADE,
                band INTEGER NOT NULL,
                value INTEGER NOT NULL,
                simhash INTEGER NOT NULL,
                PRIMARY KEY (content_id, band)
            )
            """,
            "CREATE INDEX content_bands_lookup ON content_bands(band, value, content_id, simhash)",
            """
            CREATE TABLE content_links (
                content_id INTEGER NOT NULL REFERENCES contents(id) ON DELETE CASCADE,
                related_id INTEGER NOT NULL REFERENCES contents(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                distance INTEGER NOT NULL,
                PRIMARY KEY (content_id, related_id)
            )
            """,
            "CREATE INDEX content_links_related ON content_links(related_id)",
        ])

    /// Ranking: a pin flag, the tier and a 0...1 importance boost per content. Importance is
    /// recomputed from copy history by `RankingService`; the index serves unfiltered listings.
    private static let version4 = Migration(
        version: 4,
        statements: [
            "ALTER TABLE contents ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE contents ADD COLUMN tier TEXT NOT NULL DEFAULT 'hot'",
            "ALTER TABLE contents ADD COLUMN importance REAL NOT NULL DEFAULT 0",
            "CREATE INDEX contents_importance ON contents(importance DESC, last_copied_at DESC, id DESC)",
            "CREATE INDEX copy_events_content_recent ON copy_events(content_id, copied_at DESC, id DESC)",
        ])

    /// User actions: star, soft delete (undoable; hidden from search and views until purged),
    /// a net more/less-like-this counter, and an append-only log of every action with a snapshot
    /// of the item's features. The log outlives its content (`ON DELETE SET NULL`) so the
    /// signals stay usable for a later learning model.
    private static let version5 = Migration(
        version: 5,
        statements: [
            "ALTER TABLE contents ADD COLUMN starred INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE contents ADD COLUMN deleted_at REAL",
            "ALTER TABLE contents ADD COLUMN feedback INTEGER NOT NULL DEFAULT 0",
            "CREATE INDEX contents_deleted_at ON contents(deleted_at) WHERE deleted_at IS NOT NULL",
            """
            CREATE TABLE feedback_events (
                id INTEGER PRIMARY KEY,
                content_id INTEGER REFERENCES contents(id) ON DELETE SET NULL,
                action TEXT NOT NULL CHECK (action IN
                    ('pin', 'unpin', 'star', 'unstar', 'delete', 'restore', 'recopy', 'more', 'less')),
                created_at REAL NOT NULL,
                kind TEXT NOT NULL,
                app_bundle_id TEXT,
                importance REAL NOT NULL,
                copy_count INTEGER NOT NULL
            )
            """,
            "CREATE INDEX feedback_events_content_id ON feedback_events(content_id)",
        ])

    /// Sessions: stable identity by first event (so recomputing keeps ids and topic links), how the
    /// session started, and summary metadata. Existing copy events get their session from
    /// `SessionService.rebuild`.
    private static let version6 = Migration(
        version: 6,
        statements: [
            "ALTER TABLE sessions ADD COLUMN first_event_id INTEGER",
            "ALTER TABLE sessions ADD COLUMN event_count INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE sessions ADD COLUMN start_reason TEXT NOT NULL DEFAULT 'first'",
            "ALTER TABLE sessions ADD COLUMN start_detail TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE sessions ADD COLUMN dominant_apps TEXT NOT NULL DEFAULT '[]'",
            "ALTER TABLE sessions ADD COLUMN top_entities TEXT NOT NULL DEFAULT '[]'",
            "CREATE UNIQUE INDEX sessions_first_event_id ON sessions(first_event_id)",
            "CREATE INDEX sessions_started_at ON sessions(started_at DESC)",
            "CREATE INDEX copy_events_session_id ON copy_events(session_id)",
        ])
}
