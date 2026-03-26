import Foundation
import GRDB

enum Migration_V9 {
  static func register(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("wuhu_v9_session_groups") { db in
      try db.create(table: "session_groups") { t in
        t.column("id", .text).primaryKey()
        t.column("name", .text).notNull()
        t.column("profileName", .text)
        t.column("isDefault", .boolean).notNull().defaults(to: false)
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
      }
      try db.create(
        index: "session_groups_unique_name",
        on: "session_groups",
        columns: ["name"],
        unique: true,
      )

      let now = Date()
      try db.execute(
        sql: """
        INSERT INTO session_groups (id, name, profileName, isDefault, createdAt, updatedAt)
        VALUES (?, ?, NULL, 1, ?, ?)
        """,
        arguments: [WuhuSessionGroup.defaultID, "Inbox", now, now],
      )

      try db.alter(table: "sessions") { t in
        t.add(column: "sessionGroupID", .text).notNull().defaults(to: WuhuSessionGroup.defaultID)
        t.add(column: "profileName", .text)
      }
      try db.create(index: "sessions_sessionGroupID", on: "sessions", columns: ["sessionGroupID"])
      try db.execute(
        sql: "UPDATE sessions SET sessionGroupID = ? WHERE sessionGroupID IS NULL",
        arguments: [WuhuSessionGroup.defaultID],
      )
    }
  }
}
