import Foundation
import GRDB
import WuhuAPI

/// Persists channels, members, and messages in the shared ``WuhuDatabase``.
public actor SQLiteChannelStore {
  private let dbQueue: DatabaseQueue

  public init(database: WuhuDatabase) {
    dbQueue = database.dbQueue
  }

  // MARK: - Row types

  struct ChannelRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "channels"

    var id: String
    var name: String
    var topic: String?
    var kind: String
    var createdAt: Date
    var updatedAt: Date

    func toModel() -> WuhuChannel {
      .init(
        id: id,
        name: name,
        topic: topic,
        kind: WuhuChannelKind(rawValue: kind) ?? .channel,
        createdAt: createdAt,
        updatedAt: updatedAt,
      )
    }
  }

  struct ChannelMemberRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "channel_members"

    var channelID: String
    var userID: String
    var role: String
    var joinedAt: Date
  }

  struct ChannelMessageRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "channel_messages"

    var id: Int64?
    var channelID: String
    var authorID: String
    var content: String
    var threadID: Int64?
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
      id = inserted.rowID
    }
  }

  // MARK: - Channels

  public func createChannel(name: String, topic: String? = nil, kind: WuhuChannelKind = .channel) async throws -> WuhuChannel {
    let now = Date()
    let id = UUID().uuidString.lowercased()
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw WuhuChannelStoreError.invalidChannelName("Channel name cannot be empty")
    }

    return try await dbQueue.write { db in
      var row = ChannelRow(
        id: id,
        name: trimmed,
        topic: topic?.trimmingCharacters(in: .whitespacesAndNewlines),
        kind: kind.rawValue,
        createdAt: now,
        updatedAt: now,
      )
      try row.insert(db)
      return row.toModel()
    }
  }

  public func getChannel(id: String) async throws -> WuhuChannel {
    try await dbQueue.read { db in
      guard let row = try ChannelRow.fetchOne(db, key: id) else {
        throw WuhuChannelStoreError.channelNotFound(id)
      }
      return row.toModel()
    }
  }

  public func listChannels() async throws -> [WuhuChannel] {
    try await dbQueue.read { db in
      try ChannelRow.order(Column("name").asc).fetchAll(db).map { $0.toModel() }
    }
  }

  public func updateChannel(id: String, name: String?, topic: String?) async throws -> WuhuChannel {
    try await dbQueue.write { db in
      guard var row = try ChannelRow.fetchOne(db, key: id) else {
        throw WuhuChannelStoreError.channelNotFound(id)
      }

      if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
        row.name = name
      }
      if let topic {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        row.topic = trimmed.isEmpty ? nil : trimmed
      }

      row.updatedAt = Date()
      try row.update(db)
      return row.toModel()
    }
  }

  public func deleteChannel(id: String) async throws {
    try await dbQueue.write { db in
      guard let row = try ChannelRow.fetchOne(db, key: id) else {
        throw WuhuChannelStoreError.channelNotFound(id)
      }
      _ = try row.delete(db)
    }
  }

  // MARK: - Members

  public func addMember(channelID: String, userID: String, role: WuhuChannelMemberRole = .member) async throws -> WuhuChannelMember {
    let now = Date()

    return try await dbQueue.write { db in
      guard let _ = try ChannelRow.fetchOne(db, key: channelID) else {
        throw WuhuChannelStoreError.channelNotFound(channelID)
      }

      // Fetch username from users table
      guard let userRow = try SQLiteUserStore.UserRow.fetchOne(db, key: userID) else {
        throw WuhuChannelStoreError.userNotFound(userID)
      }

      var row = ChannelMemberRow(
        channelID: channelID,
        userID: userID,
        role: role.rawValue,
        joinedAt: now,
      )
      // Use INSERT OR REPLACE so re-adding updates role
      try row.save(db)

      return WuhuChannelMember(
        channelID: channelID,
        userID: userID,
        username: userRow.username,
        role: role,
        joinedAt: now,
      )
    }
  }

  public func removeMember(channelID: String, userID: String) async throws {
    try await dbQueue.write { db in
      try db.execute(
        sql: "DELETE FROM channel_members WHERE channelID = ? AND userID = ?",
        arguments: [channelID, userID],
      )
    }
  }

  public func listMembers(channelID: String) async throws -> [WuhuChannelMember] {
    try await dbQueue.read { db in
      guard let _ = try ChannelRow.fetchOne(db, key: channelID) else {
        throw WuhuChannelStoreError.channelNotFound(channelID)
      }

      let rows = try Row.fetchAll(db, sql: """
      SELECT cm.channelID, cm.userID, u.username, cm.role, cm.joinedAt
      FROM channel_members cm
      JOIN users u ON u.id = cm.userID
      WHERE cm.channelID = ?
      ORDER BY cm.joinedAt ASC
      """, arguments: [channelID])

      return rows.map { row in
        WuhuChannelMember(
          channelID: row["channelID"],
          userID: row["userID"],
          username: row["username"],
          role: WuhuChannelMemberRole(rawValue: row["role"]) ?? .member,
          joinedAt: row["joinedAt"],
        )
      }
    }
  }

  // MARK: - Messages

  public func postMessage(
    channelID: String,
    authorID: String,
    content: String,
    threadID: Int64? = nil,
  ) async throws -> WuhuChannelMessage {
    let now = Date()
    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedContent.isEmpty else {
      throw WuhuChannelStoreError.emptyMessage
    }

    return try await dbQueue.write { db in
      guard let _ = try ChannelRow.fetchOne(db, key: channelID) else {
        throw WuhuChannelStoreError.channelNotFound(channelID)
      }

      guard let userRow = try SQLiteUserStore.UserRow.fetchOne(db, key: authorID) else {
        throw WuhuChannelStoreError.userNotFound(authorID)
      }

      // Validate threadID exists and belongs to same channel
      if let threadID {
        guard let threadMsg = try ChannelMessageRow.fetchOne(db, key: threadID),
              threadMsg.channelID == channelID
        else {
          throw WuhuChannelStoreError.threadNotFound(threadID)
        }
        // Threads can't be nested — threadID must be a top-level message
        if threadMsg.threadID != nil {
          throw WuhuChannelStoreError.nestedThreadsNotAllowed
        }
      }

      var row = ChannelMessageRow(
        id: nil,
        channelID: channelID,
        authorID: authorID,
        content: trimmedContent,
        threadID: threadID,
        createdAt: now,
      )
      try row.insert(db)

      // Update channel's updatedAt
      try db.execute(
        sql: "UPDATE channels SET updatedAt = ? WHERE id = ?",
        arguments: [now, channelID],
      )

      return WuhuChannelMessage(
        id: row.id!,
        channelID: channelID,
        authorID: authorID,
        authorUsername: userRow.username,
        content: trimmedContent,
        threadID: threadID,
        createdAt: now,
      )
    }
  }

  public func listMessages(
    channelID: String,
    beforeID: Int64? = nil,
    limit: Int = 50,
  ) async throws -> [WuhuChannelMessage] {
    try await dbQueue.read { db in
      guard let _ = try ChannelRow.fetchOne(db, key: channelID) else {
        throw WuhuChannelStoreError.channelNotFound(channelID)
      }

      var sql = """
      SELECT m.id, m.channelID, m.authorID, u.username AS authorUsername,
             m.content, m.threadID, m.createdAt
      FROM channel_messages m
      JOIN users u ON u.id = m.authorID
      WHERE m.channelID = ?
      """
      var args: [any DatabaseValueConvertible] = [channelID]

      if let beforeID {
        sql += " AND m.id < ?"
        args.append(beforeID)
      }

      sql += " ORDER BY m.id DESC LIMIT ?"
      args.append(limit)

      let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

      // Return in chronological order (oldest first)
      return rows.reversed().map { row in
        WuhuChannelMessage(
          id: row["id"],
          channelID: row["channelID"],
          authorID: row["authorID"],
          authorUsername: row["authorUsername"],
          content: row["content"],
          threadID: row["threadID"],
          createdAt: row["createdAt"],
        )
      }
    }
  }

  /// Get messages since a cursor (for SSE catch-up).
  public func getMessagesSince(
    channelID: String,
    sinceID: Int64,
    limit: Int = 200,
  ) async throws -> [WuhuChannelMessage] {
    try await dbQueue.read { db in
      let rows = try Row.fetchAll(db, sql: """
      SELECT m.id, m.channelID, m.authorID, u.username AS authorUsername,
             m.content, m.threadID, m.createdAt
      FROM channel_messages m
      JOIN users u ON u.id = m.authorID
      WHERE m.channelID = ? AND m.id > ?
      ORDER BY m.id ASC
      LIMIT ?
      """, arguments: [channelID, sinceID, limit])

      return rows.map { row in
        WuhuChannelMessage(
          id: row["id"],
          channelID: row["channelID"],
          authorID: row["authorID"],
          authorUsername: row["authorUsername"],
          content: row["content"],
          threadID: row["threadID"],
          createdAt: row["createdAt"],
        )
      }
    }
  }
}

public enum WuhuChannelStoreError: Error, Sendable, CustomStringConvertible {
  case channelNotFound(String)
  case invalidChannelName(String)
  case channelNameAlreadyExists(String)
  case userNotFound(String)
  case emptyMessage
  case threadNotFound(Int64)
  case nestedThreadsNotAllowed

  public var description: String {
    switch self {
    case let .channelNotFound(id):
      "Channel not found: \(id)"
    case let .invalidChannelName(reason):
      "Invalid channel name: \(reason)"
    case let .channelNameAlreadyExists(name):
      "Channel name already exists: \(name)"
    case let .userNotFound(id):
      "User not found: \(id)"
    case .emptyMessage:
      "Message content cannot be empty"
    case let .threadNotFound(id):
      "Thread parent message not found: \(id)"
    case .nestedThreadsNotAllowed:
      "Cannot reply to a thread reply — threads are one level deep"
    }
  }
}
