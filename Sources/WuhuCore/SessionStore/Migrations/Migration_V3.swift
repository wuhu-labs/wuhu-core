import GRDB

enum Migration_V3 {
  static func register(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("wuhu_contracts_v3_channels") { db in
      try db.alter(table: "sessions") { t in
        // WuhuSessionType was removed in v6; use the literal default.
        t.add(column: "sessionType", .text).notNull().defaults(to: "coding")
        t.add(column: "displayStartEntryID", .integer)
      }

      try db.create(table: "session_child_status") { t in
        t.column("parentSessionID", .text).notNull().indexed().references("sessions", onDelete: .cascade)
        t.column("childSessionID", .text).notNull().indexed().references("sessions", onDelete: .cascade)
        t.column("lastNotifiedFinalEntryID", .integer)
        t.column("lastReadFinalEntryID", .integer)
        t.column("updatedAt", .datetime).notNull()
        t.primaryKey(["parentSessionID", "childSessionID"])
      }
    }
  }
}
