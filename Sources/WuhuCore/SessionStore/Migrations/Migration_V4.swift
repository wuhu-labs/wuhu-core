import GRDB

enum Migration_V4 {
  static func register(in migrator: inout DatabaseMigrator) {
    // ── v4: custom title ───────────────────────────────────────────────
    migrator.registerMigration("wuhu_v4_custom_title") { db in
      try db.alter(table: "sessions") { t in
        t.add(column: "customTitle", .text)
      }
    }
  }
}
