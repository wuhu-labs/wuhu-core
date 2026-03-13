import GRDB

enum Migration_V5 {
  static func register(in migrator: inout DatabaseMigrator) {
    // ── v5: archive flag ───────────────────────────────────────────────
    migrator.registerMigration("wuhu_v5_archive") { db in
      try db.alter(table: "sessions") { t in
        t.add(column: "isArchived", .boolean).notNull().defaults(to: false)
      }
    }
  }
}
