public enum Schema {
    public static let latestVersion = 2
    public static let migrations = [version1, version2]
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

    /// Full-text index over `contents.text`. The trigram tokenizer matches substrings
    /// ("serDa" finds "getUserData") and ignores case; queries need at least three characters.
    private static let version2 = Migration(
        version: 2,
        statements: [
            """
            CREATE VIRTUAL TABLE contents_fts USING fts5(
                text, content='contents', content_rowid='id', tokenize='trigram'
            )
            """,
            """
            CREATE TRIGGER contents_fts_insert AFTER INSERT ON contents BEGIN
                INSERT INTO contents_fts(rowid, text) VALUES (new.id, new.text);
            END
            """,
            """
            CREATE TRIGGER contents_fts_delete AFTER DELETE ON contents BEGIN
                INSERT INTO contents_fts(contents_fts, rowid, text)
                VALUES ('delete', old.id, old.text);
            END
            """,
            """
            CREATE TRIGGER contents_fts_update AFTER UPDATE OF text ON contents BEGIN
                INSERT INTO contents_fts(contents_fts, rowid, text)
                VALUES ('delete', old.id, old.text);
                INSERT INTO contents_fts(rowid, text) VALUES (new.id, new.text);
            END
            """,
            "INSERT INTO contents_fts(contents_fts) VALUES ('rebuild')",
        ])
}
