import GRDB

enum Migration_V6 {
  static func register(in migrator: inout DatabaseMigrator) {
    // ── v6: mounts (data-preserving) ───────────────────────────────────
    //
    // Replaces the `environments` table with `mount_templates` + `mounts`.
    // Drops unused columns from `sessions` via the rename-copy-drop
    // pattern (SQLite doesn't support DROP COLUMN before 3.35.0).
    //
    // Preserved tables (no schema change):
    //   session_entries, tool_call_status, user_queue_pending,
    //   user_queue_journal, system_queue_pending, system_queue_journal
    migrator.registerMigration("wuhu_v6_mounts") { db in
      // 1. Create mount_templates (replaces environments)
      try db.create(table: "mount_templates") { t in
        t.column("id", .text).primaryKey()
        t.column("name", .text).notNull()
        t.column("type", .text).notNull()
        t.column("templatePath", .text).notNull()
        t.column("workspacesPath", .text).notNull()
        t.column("startupScript", .text)
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
      }
      try db.create(index: "mount_templates_unique_name", on: "mount_templates", columns: ["name"], unique: true)

      // 2. Migrate sessions: drop removed columns, make cwd nullable.
      //
      //    We use the create-new → copy → drop-old → rename pattern
      //    instead of rename-old → create → copy → drop-old, because
      //    SQLite 3.25+ rewrites FK references in *other* tables when
      //    you rename the referenced table. By keeping the original
      //    "sessions" name untouched until the DROP, the FKs in
      //    session_entries / tool_call_status / queues continue to
      //    resolve correctly after the final RENAME.

      // Temporarily disable FK enforcement so the DROP doesn't cascade.
      try db.execute(sql: "PRAGMA foreign_keys = OFF")

      try db.execute(sql: """
      CREATE TABLE _sessions_new (
        id TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        model TEXT NOT NULL,
        effectiveReasoningEffort TEXT,
        pendingProvider TEXT,
        pendingModel TEXT,
        pendingReasoningEffort TEXT,
        executionStatus TEXT NOT NULL,
        cwd TEXT,
        parentSessionID TEXT,
        customTitle TEXT,
        isArchived BOOLEAN NOT NULL DEFAULT 0,
        createdAt DATETIME NOT NULL,
        updatedAt DATETIME NOT NULL,
        headEntryID INTEGER,
        tailEntryID INTEGER
      )
      """)

      // Copy data — map only the columns that survived.
      try db.execute(sql: """
      INSERT INTO _sessions_new (
        id, provider, model,
        effectiveReasoningEffort, pendingProvider, pendingModel, pendingReasoningEffort,
        executionStatus, cwd, parentSessionID,
        customTitle, isArchived,
        createdAt, updatedAt,
        headEntryID, tailEntryID
      )
      SELECT
        id, provider, model,
        effectiveReasoningEffort, pendingProvider, pendingModel, pendingReasoningEffort,
        executionStatus, cwd, parentSessionID,
        customTitle, isArchived,
        createdAt, updatedAt,
        headEntryID, tailEntryID
      FROM sessions
      """)

      // Drop the old table (FKs off, so no cascade into session_entries)
      try db.execute(sql: "DROP TABLE sessions")

      // Rename the new table into place. Because no existing FK
      // references "_sessions_new", SQLite won't rewrite any FK
      // definitions in other tables. The existing "REFERENCES sessions"
      // clauses now resolve to this renamed table.
      try db.execute(sql: "ALTER TABLE _sessions_new RENAME TO sessions")

      // 3. Create mounts table
      try db.create(table: "mounts") { t in
        t.column("id", .text).primaryKey()
        t.column("sessionID", .text).notNull().indexed().references("sessions", onDelete: .cascade)
        t.column("name", .text).notNull()
        t.column("path", .text).notNull()
        t.column("mountTemplateID", .text)
        t.column("isPrimary", .boolean).notNull().defaults(to: false)
        t.column("createdAt", .datetime).notNull()
      }

      // 5. Drop obsolete tables
      try db.execute(sql: "DROP TABLE IF EXISTS session_child_status")
      try db.execute(sql: "DROP TABLE IF EXISTS environments")

      // 6. Repair data integrity issues from historical bugs before
      //    re-enabling FK enforcement.

      // Remove entries referencing sessions that no longer exist.
      try db.execute(sql: """
        DELETE FROM session_entries
        WHERE sessionID NOT IN (SELECT id FROM sessions)
      """)

      // Fix orphaned parentEntryID references (e.g. parentEntryID = 0).
      try db.execute(sql: """
        UPDATE session_entries SET parentEntryID = NULL
        WHERE parentEntryID IS NOT NULL
          AND parentEntryID NOT IN (SELECT id FROM session_entries)
      """)

      // 7. Re-enable FK enforcement and verify integrity
      try db.execute(sql: "PRAGMA foreign_keys = ON")

      // Verify no FK violations were introduced
      if let violations = try Row.fetchOne(db, sql: "PRAGMA foreign_key_check") {
        throw StoreError.sessionCorrupt(
          "Foreign key violations after v6 migration: \(violations)",
        )
      }
    }
  }
}
