import GRDB

enum Migration_V7 {
  static func register(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("wuhu_v7_runner") { db in
      try db.alter(table: "mounts") { t in
        t.add(column: "runnerID", .text).notNull().defaults(to: "local")
      }
    }
  }
}
