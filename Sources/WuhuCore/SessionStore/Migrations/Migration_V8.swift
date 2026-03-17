import GRDB

enum Migration_V8 {
  static func register(in migrator: inout DatabaseMigrator) {
    // ── v8: users, channels, channel_members, channel_messages ──────
    migrator.registerMigration("wuhu_v8_channels") { db in
      try db.create(table: "users") { t in
        t.column("id", .text).primaryKey()
        t.column("username", .text).notNull()
        t.column("kind", .text).notNull().defaults(to: "human")
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
      }
      try db.create(
        index: "users_unique_username",
        on: "users",
        columns: ["username"],
        unique: true,
      )

      try db.create(table: "channels") { t in
        t.column("id", .text).primaryKey()
        t.column("name", .text).notNull()
        t.column("topic", .text)
        t.column("kind", .text).notNull().defaults(to: "channel")
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
      }
      try db.create(
        index: "channels_unique_name",
        on: "channels",
        columns: ["name"],
        unique: true,
      )

      try db.create(table: "channel_members") { t in
        t.column("channelID", .text).notNull()
          .references("channels", onDelete: .cascade)
        t.column("userID", .text).notNull()
          .references("users", onDelete: .cascade)
        t.column("role", .text).notNull().defaults(to: "member")
        t.column("joinedAt", .datetime).notNull()
        t.primaryKey(["channelID", "userID"])
      }

      try db.create(table: "channel_messages") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("channelID", .text).notNull()
          .indexed()
          .references("channels", onDelete: .cascade)
        t.column("authorID", .text).notNull()
          .references("users", onDelete: .restrict)
        t.column("content", .text).notNull()
        t.column("threadID", .integer)
          .references("channel_messages", onDelete: .cascade)
        t.column("createdAt", .datetime).notNull()
      }
      try db.create(
        index: "channel_messages_channel_created",
        on: "channel_messages",
        columns: ["channelID", "createdAt"],
      )
      try db.create(
        index: "channel_messages_thread",
        on: "channel_messages",
        columns: ["threadID"],
        condition: Column("threadID") != nil,
      )
    }
  }
}
