public enum Schema {
    public static let migrator = Migrator(migrations: [version1])

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
}
