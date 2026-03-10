import GRDB

enum Migration_V8 {
  static func register(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("wuhu_v8_cost_limit") { db in
      try db.alter(table: "sessions") { t in
        t.add(column: "costLimitCents", .integer)
      }
    }
  }
}
