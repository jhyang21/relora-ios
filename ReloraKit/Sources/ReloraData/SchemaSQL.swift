import Foundation

/// The local SQLite schema, ported verbatim from
/// apps/mobile/src/db/schema.ts at RN schema version 9 (the `SCHEMA_VERSION_TRANSCRIPT_SEARCH`
/// milestone in apps/mobile/src/db/client.ts — the last version that repo ever reached).
///
/// The native app takes a clean cut: there is no history of RN schema versions 1–8 to
/// replay, so this is authored as ONE GRDB migration ("v9-baseline") rather than the nine
/// incremental migrations the RN client accumulated. Every statement below is copied
/// character-for-character from the *final* shape those migrations converge on — table and
/// column names, index names, and trigger bodies (including the `strftime` call) are
/// unchanged, so a person diffing this against schema.ts should see no drift beyond syntax.
enum SchemaSQL {
    /// Same trigger body substituted with `NEW`/`OLD` — kept as a function, exactly like
    /// `refreshContactInteractionSql` in schema.ts, so the six call sites can never drift
    /// from each other.
    private static func refreshContactInteractionSQL(contactIDExpr: String, userIDExpr: String) -> String {
        """
        UPDATE contacts
        SET last_interaction_at = (
              SELECT MAX(updated_at)
              FROM (
                SELECT updated_at
                FROM key_things
                WHERE contact_id = \(contactIDExpr)
                  AND user_id = \(userIDExpr)
                  AND deleted_at IS NULL
                UNION ALL
                SELECT updated_at
                FROM memories
                WHERE contact_id = \(contactIDExpr)
                  AND user_id = \(userIDExpr)
                  AND deleted_at IS NULL
              )
            ),
            updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
        WHERE id = \(contactIDExpr)
          AND user_id = \(userIDExpr)
        """
    }

    private static let contactsTableSQL = """
        CREATE TABLE IF NOT EXISTS contacts (
          id TEXT PRIMARY KEY NOT NULL,
          user_id TEXT NOT NULL,
          name TEXT NOT NULL,
          avatar_url TEXT,
          descriptors TEXT NOT NULL DEFAULT '[]',
          phone_number TEXT,
          email TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          is_dirty INTEGER NOT NULL DEFAULT 0,
          dirty_at TEXT,
          last_interaction_at TEXT,
          deleted_at TEXT,
          UNIQUE (id, user_id)
        )
        """

    private static let keyThingsTableSQL = """
        CREATE TABLE IF NOT EXISTS key_things (
          id TEXT PRIMARY KEY NOT NULL,
          contact_id TEXT NOT NULL,
          user_id TEXT NOT NULL,
          text TEXT NOT NULL,
          source TEXT NOT NULL CHECK(source IN ('manual', 'voice')),
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          is_dirty INTEGER NOT NULL DEFAULT 0,
          dirty_at TEXT,
          deleted_at TEXT,
          FOREIGN KEY(contact_id, user_id) REFERENCES contacts(id, user_id) ON DELETE CASCADE
        )
        """

    private static let memoriesTableSQL = """
        CREATE TABLE IF NOT EXISTS memories (
          id TEXT PRIMARY KEY NOT NULL,
          contact_id TEXT NOT NULL,
          user_id TEXT NOT NULL,
          text TEXT NOT NULL,
          labels TEXT NOT NULL DEFAULT '[]',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          is_dirty INTEGER NOT NULL DEFAULT 0,
          dirty_at TEXT,
          audio_url TEXT,
          audio_local_uri TEXT,
          transcript TEXT,
          source TEXT NOT NULL CHECK(source IN ('manual', 'voice')),
          deleted_at TEXT,
          UNIQUE (id, contact_id, user_id),
          FOREIGN KEY(contact_id, user_id) REFERENCES contacts(id, user_id) ON DELETE CASCADE
        )
        """

    private static let remindersTableSQL = """
        CREATE TABLE IF NOT EXISTS reminders (
          id TEXT PRIMARY KEY NOT NULL,
          contact_id TEXT NOT NULL,
          user_id TEXT NOT NULL,
          memory_id TEXT,
          title TEXT NOT NULL,
          remind_at TEXT NOT NULL,
          status TEXT NOT NULL CHECK(status IN ('scheduled', 'fired', 'dismissed')),
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          is_dirty INTEGER NOT NULL DEFAULT 0,
          dirty_at TEXT,
          deleted_at TEXT,
          notification_id TEXT,
          FOREIGN KEY(contact_id, user_id) REFERENCES contacts(id, user_id) ON DELETE CASCADE,
          FOREIGN KEY(memory_id, contact_id, user_id) REFERENCES memories(id, contact_id, user_id)
        )
        """

    private static let voiceNoteUsageEventsTableSQL = """
        CREATE TABLE IF NOT EXISTS voice_note_usage_events (
          id TEXT PRIMARY KEY NOT NULL,
          user_id TEXT NOT NULL,
          processed_at TEXT NOT NULL,
          source TEXT NOT NULL,
          server_synced_at TEXT
        )
        """

    private static let syncStateTableSQL = """
        CREATE TABLE IF NOT EXISTS sync_state (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          user_id TEXT,
          server_cursor TEXT,
          last_sync_at TEXT
        )
        """

    private static let searchIndexMetaTableSQL = """
        CREATE TABLE IF NOT EXISTS search_index_meta (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        )
        """

    private static let appSettingsTableSQL = """
        CREATE TABLE IF NOT EXISTS app_settings (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        )
        """

    /// Derived search index over every contact's own fields plus its key things,
    /// memories, and — when the user keeps them — the transcripts behind those
    /// memories. Holds no source data, so a column change is a drop and rebuild.
    static let contactSearchTableSQL = """
        CREATE VIRTUAL TABLE IF NOT EXISTS contact_search USING fts5(
          contact_id UNINDEXED,
          name,
          descriptors,
          phone_number,
          email,
          key_things,
          memories,
          transcripts
        )
        """

    /// Ordered schema statements executed by the "v9-baseline" migration. Order matches
    /// `schemaStatements` in schema.ts exactly: tables, seed rows, indexes, the FTS5 virtual
    /// table, then triggers (which reference the tables and indexes created above).
    static let migrationStatements: [String] = [
        contactsTableSQL,
        keyThingsTableSQL,
        memoriesTableSQL,
        remindersTableSQL,
        voiceNoteUsageEventsTableSQL,
        syncStateTableSQL,
        searchIndexMetaTableSQL,
        appSettingsTableSQL,
        "INSERT OR IGNORE INTO sync_state (id, user_id, server_cursor, last_sync_at) VALUES (1, NULL, NULL, NULL)",
        "INSERT OR IGNORE INTO search_index_meta (key, value) VALUES ('contact_search_needs_rebuild', '1')",
        "CREATE INDEX IF NOT EXISTS idx_contacts_user_updated ON contacts(user_id, updated_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_contacts_user_dirty ON contacts(user_id, is_dirty, dirty_at)",
        "CREATE INDEX IF NOT EXISTS idx_key_things_user_dirty ON key_things(user_id, is_dirty, dirty_at)",
        "CREATE INDEX IF NOT EXISTS idx_key_things_contact_user_active_updated ON key_things(contact_id, user_id, updated_at DESC) WHERE deleted_at IS NULL",
        "CREATE INDEX IF NOT EXISTS idx_memories_user_dirty ON memories(user_id, is_dirty, dirty_at)",
        "CREATE INDEX IF NOT EXISTS idx_memories_contact_created ON memories(contact_id, created_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_memories_contact_user_active_updated ON memories(contact_id, user_id, updated_at DESC) WHERE deleted_at IS NULL",
        "CREATE INDEX IF NOT EXISTS idx_reminders_user_dirty ON reminders(user_id, is_dirty, dirty_at)",
        "CREATE INDEX IF NOT EXISTS idx_reminders_user_remind_at ON reminders(user_id, remind_at ASC)",
        "CREATE INDEX IF NOT EXISTS idx_reminders_contact_remind_at ON reminders(contact_id, remind_at ASC)",
        "CREATE INDEX IF NOT EXISTS idx_voice_note_usage_user_processed_at ON voice_note_usage_events(user_id, processed_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_voice_note_usage_user_sync ON voice_note_usage_events(user_id, server_synced_at, processed_at DESC)",
        contactSearchTableSQL,
        """
        CREATE TRIGGER IF NOT EXISTS trg_memories_null_reminder_memory_before_delete
        BEFORE DELETE ON memories
        FOR EACH ROW
        BEGIN
          UPDATE reminders
          SET memory_id = NULL
          WHERE memory_id = OLD.id
            AND contact_id = OLD.contact_id
            AND user_id = OLD.user_id;
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS trg_key_things_sync_contact_after_insert
        AFTER INSERT ON key_things
        FOR EACH ROW
        BEGIN
          \(refreshContactInteractionSQL(contactIDExpr: "NEW.contact_id", userIDExpr: "NEW.user_id"));
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS trg_key_things_sync_contact_after_update
        AFTER UPDATE ON key_things
        FOR EACH ROW
        BEGIN
          \(refreshContactInteractionSQL(contactIDExpr: "OLD.contact_id", userIDExpr: "OLD.user_id"));
          \(refreshContactInteractionSQL(contactIDExpr: "NEW.contact_id", userIDExpr: "NEW.user_id"));
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS trg_key_things_sync_contact_after_delete
        AFTER DELETE ON key_things
        FOR EACH ROW
        BEGIN
          \(refreshContactInteractionSQL(contactIDExpr: "OLD.contact_id", userIDExpr: "OLD.user_id"));
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS trg_memories_sync_contact_after_insert
        AFTER INSERT ON memories
        FOR EACH ROW
        BEGIN
          \(refreshContactInteractionSQL(contactIDExpr: "NEW.contact_id", userIDExpr: "NEW.user_id"));
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS trg_memories_sync_contact_after_update
        AFTER UPDATE ON memories
        FOR EACH ROW
        BEGIN
          \(refreshContactInteractionSQL(contactIDExpr: "OLD.contact_id", userIDExpr: "OLD.user_id"));
          \(refreshContactInteractionSQL(contactIDExpr: "NEW.contact_id", userIDExpr: "NEW.user_id"));
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS trg_memories_sync_contact_after_delete
        AFTER DELETE ON memories
        FOR EACH ROW
        BEGIN
          \(refreshContactInteractionSQL(contactIDExpr: "OLD.contact_id", userIDExpr: "OLD.user_id"));
        END
        """
    ]
}
