import GRDB

enum Migration_V2 {
  static func register(in migrator: inout DatabaseMigrator) {
    // ── v2: environments table + environmentID on sessions ─────────────
    migrator.registerMigration("wuhu_contracts_v2_environments") { db in
      try db.create(table: "environments") { t in
        t.column("id", .text).primaryKey()
        t.column("name", .text).notNull()
        t.column("type", .text).notNull()
        t.column("path", .text).notNull()
        t.column("templatePath", .text)
        t.column("startupScript", .text)
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
      }
      try db.create(index: "environments_unique_name", on: "environments", columns: ["name"], unique: true)

      try db.alter(table: "sessions") { t in
        t.add(column: "environmentID", .text)
      }
    }
  }
}
