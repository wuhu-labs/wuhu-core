import GRDB

enum Migration_V1 {
  static func register(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("wuhu_contracts_v1") { db in
      // Hard reset: this repo intentionally does not migrate older schemas.
      try db.execute(sql: "DROP TABLE IF EXISTS tool_call_status")
      try db.execute(sql: "DROP TABLE IF EXISTS system_queue_pending")
      try db.execute(sql: "DROP TABLE IF EXISTS system_queue_journal")
      try db.execute(sql: "DROP TABLE IF EXISTS user_queue_pending")
      try db.execute(sql: "DROP TABLE IF EXISTS user_queue_journal")
      try db.execute(sql: "DROP TABLE IF EXISTS session_entries")
      try db.execute(sql: "DROP TABLE IF EXISTS session_child_status")
      try db.execute(sql: "DROP TABLE IF EXISTS sessions")
      try db.execute(sql: "DROP TABLE IF EXISTS environments")

      try db.create(table: "sessions") { t in
        t.column("id", .text).primaryKey()
        t.column("provider", .text).notNull()
        t.column("model", .text).notNull()
        t.column("effectiveReasoningEffort", .text)
        t.column("pendingProvider", .text)
        t.column("pendingModel", .text)
        t.column("pendingReasoningEffort", .text)
        t.column("executionStatus", .text).notNull()
        t.column("environmentName", .text).notNull()
        t.column("environmentType", .text).notNull()
        t.column("environmentPath", .text).notNull()
        t.column("environmentTemplatePath", .text)
        t.column("environmentStartupScript", .text)
        t.column("cwd", .text).notNull()
        t.column("runnerName", .text)
        t.column("parentSessionID", .text)
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
        t.column("headEntryID", .integer)
        t.column("tailEntryID", .integer)
      }

      try db.create(table: "session_entries") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("sessionID", .text).notNull().indexed().references("sessions", onDelete: .cascade)
        t.column("parentEntryID", .integer).references("session_entries", onDelete: .restrict)
        t.column("type", .text).notNull().indexed()
        t.column("payload", .blob).notNull()
        t.column("createdAt", .datetime).notNull().indexed()
      }
      try db.create(index: "session_entries_unique_parent", on: "session_entries", columns: ["parentEntryID"], unique: true, condition: Column("parentEntryID") != nil)
      try db.create(index: "session_entries_unique_header_per_session", on: "session_entries", columns: ["sessionID"], unique: true, condition: Column("parentEntryID") == nil)

      try db.create(table: "tool_call_status") { t in
        t.column("sessionID", .text).notNull().indexed().references("sessions", onDelete: .cascade)
        t.column("toolCallID", .text).notNull()
        t.column("status", .text).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
        t.primaryKey(["sessionID", "toolCallID"])
      }

      try db.create(table: "user_queue_pending") { t in
        t.column("id", .text).primaryKey()
        t.column("sessionID", .text).notNull().indexed().references("sessions", onDelete: .cascade)
        t.column("lane", .text).notNull().indexed()
        t.column("enqueuedAt", .datetime).notNull().indexed()
        t.column("payload", .blob).notNull()
      }
      try db.create(table: "user_queue_journal") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("sessionID", .text).notNull().indexed().references("sessions", onDelete: .cascade)
        t.column("lane", .text).notNull().indexed()
        t.column("payload", .blob).notNull()
        t.column("createdAt", .datetime).notNull().indexed()
      }

      try db.create(table: "system_queue_pending") { t in
        t.column("id", .text).primaryKey()
        t.column("sessionID", .text).notNull().indexed().references("sessions", onDelete: .cascade)
        t.column("enqueuedAt", .datetime).notNull().indexed()
        t.column("payload", .blob).notNull()
      }
      try db.create(table: "system_queue_journal") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("sessionID", .text).notNull().indexed().references("sessions", onDelete: .cascade)
        t.column("payload", .blob).notNull()
        t.column("createdAt", .datetime).notNull().indexed()
      }
    }
  }
}
