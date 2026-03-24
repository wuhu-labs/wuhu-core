import Foundation
import GRDB
import WuhuAPI

public enum WuhuSessionGroupStoreError: Error, Sendable, CustomStringConvertible {
  case cannotModifyDefaultGroup
  case groupNotFound(String)
  case invalidName(String)
  case nameAlreadyExists(String)

  public var description: String {
    switch self {
    case .cannotModifyDefaultGroup:
      "The default Inbox group cannot be modified."
    case let .groupNotFound(id):
      "Session group not found: \(id)"
    case let .invalidName(reason):
      "Invalid session group name: \(reason)"
    case let .nameAlreadyExists(name):
      "A session group named '\(name)' already exists."
    }
  }
}

extension SQLiteSessionStore {
  public func defaultSessionGroup() async throws -> WuhuSessionGroup {
    try await getSessionGroup(id: WuhuSessionGroup.defaultID)
  }

  public func getSessionGroup(id: String) async throws -> WuhuSessionGroup {
    try await dbQueue.read { db in
      guard let row = try SessionGroupRow.fetchOne(db, key: id) else {
        throw WuhuSessionGroupStoreError.groupNotFound(id)
      }
      return row.toModel()
    }
  }

  public func listSessionGroups() async throws -> [WuhuSessionGroup] {
    try await dbQueue.read { db in
      try SessionGroupRow
        .order(Column("isDefault").desc, Column("name").asc)
        .fetchAll(db)
        .map { $0.toModel() }
    }
  }

  public func createSessionGroup(name: String, profileName: String?) async throws -> WuhuSessionGroup {
    let trimmedName = try Self.normalizedGroupName(name)
    let trimmedProfile = Self.normalizedProfileName(profileName)
    let now = Date()

    return try await dbQueue.write { db in
      if try SessionGroupRow.filter(Column("name") == trimmedName).fetchCount(db) > 0 {
        throw WuhuSessionGroupStoreError.nameAlreadyExists(trimmedName)
      }

      var row = SessionGroupRow(
        id: UUID().uuidString.lowercased(),
        name: trimmedName,
        profileName: trimmedProfile,
        isDefault: false,
        createdAt: now,
        updatedAt: now,
      )
      try row.insert(db)
      return row.toModel()
    }
  }

  public func updateSessionGroup(id: String, name: String, profileName: String?) async throws -> WuhuSessionGroup {
    let trimmedName = try Self.normalizedGroupName(name)
    let trimmedProfile = Self.normalizedProfileName(profileName)

    return try await dbQueue.write { db in
      guard var row = try SessionGroupRow.fetchOne(db, key: id) else {
        throw WuhuSessionGroupStoreError.groupNotFound(id)
      }
      if row.isDefault {
        throw WuhuSessionGroupStoreError.cannotModifyDefaultGroup
      }
      if try SessionGroupRow
        .filter(Column("name") == trimmedName && Column("id") != id)
        .fetchCount(db) > 0
      {
        throw WuhuSessionGroupStoreError.nameAlreadyExists(trimmedName)
      }

      row.name = trimmedName
      row.profileName = trimmedProfile
      row.updatedAt = Date()
      try row.update(db)
      return row.toModel()
    }
  }

  public func listSessionSummaries(
    limit: Int? = nil,
    includeArchived: Bool = false,
    sessionGroupID: String? = nil,
  ) async throws -> [WuhuSessionSummary] {
    try await dbQueue.read { db in
      var whereClauses: [String] = []
      var args: [any DatabaseValueConvertible] = []

      if !includeArchived {
        whereClauses.append("s.isArchived = 0")
      }
      if let sessionGroupID, !sessionGroupID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        whereClauses.append("s.sessionGroupID = ?")
        args.append(sessionGroupID)
      }

      let whereSQL = whereClauses.isEmpty ? "" : "WHERE " + whereClauses.joined(separator: " AND ")

      var sql = """
      WITH base_sessions AS (
        SELECT s.*
        FROM sessions s
        \(whereSQL)
        ORDER BY s.updatedAt DESC
      """
      if let limit {
        sql += "\nLIMIT ?"
        args.append(limit)
      }
      sql += """
      ),
      first_user AS (
        SELECT e.sessionID, MIN(e.id) AS entryID
        FROM session_entries e
        JOIN base_sessions s ON s.id = e.sessionID
        WHERE e.type = 'message'
          AND json_extract(CAST(e.payload AS TEXT), '$.payload.role') = 'user'
        GROUP BY e.sessionID
      ),
      last_message AS (
        SELECT e.sessionID, MAX(e.id) AS entryID
        FROM session_entries e
        JOIN base_sessions s ON s.id = e.sessionID
        WHERE e.type = 'message'
          AND json_extract(CAST(e.payload AS TEXT), '$.payload.role') IN ('user', 'assistant')
        GROUP BY e.sessionID
      )
      SELECT
        s.*,
        fu.payload AS firstUserPayload,
        lm.payload AS lastMessagePayload
      FROM base_sessions s
      LEFT JOIN first_user fui ON fui.sessionID = s.id
      LEFT JOIN session_entries fu ON fu.id = fui.entryID
      LEFT JOIN last_message lmi ON lmi.sessionID = s.id
      LEFT JOIN session_entries lm ON lm.id = lmi.entryID
      ORDER BY s.updatedAt DESC
      """

      let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
      return try rows.map(Self.makeSessionSummary)
    }
  }

  private static func normalizedGroupName(_ name: String) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw WuhuSessionGroupStoreError.invalidName("Name is required.")
    }
    return trimmed
  }

  private static func normalizedProfileName(_ profileName: String?) -> String? {
    let trimmed = profileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func makeSessionSummary(from row: Row) throws -> WuhuSessionSummary {
    let sessionRow = SessionRow(
      id: row["id"],
      provider: row["provider"],
      model: row["model"],
      effectiveReasoningEffort: row["effectiveReasoningEffort"],
      pendingProvider: row["pendingProvider"],
      pendingModel: row["pendingModel"],
      pendingReasoningEffort: row["pendingReasoningEffort"],
      executionStatus: row["executionStatus"],
      cwd: row["cwd"],
      sessionGroupID: row["sessionGroupID"],
      parentSessionID: row["parentSessionID"],
      profileName: row["profileName"],
      customTitle: row["customTitle"],
      isArchived: row["isArchived"],
      createdAt: row["createdAt"],
      updatedAt: row["updatedAt"],
      headEntryID: row["headEntryID"],
      tailEntryID: row["tailEntryID"],
    )
    let session = try sessionRow.toModel()

    let firstUserText = previewText(fromEntryPayloadData: row["firstUserPayload"], limit: 120)
    let lastPreview = preview(fromEntryPayloadData: row["lastMessagePayload"], limit: 240)
    let displayTitle = session.customTitle ?? firstUserText ?? "Untitled"

    return .init(
      session: session,
      displayTitle: displayTitle,
      firstUserMessageText: firstUserText,
      lastMessageRole: lastPreview?.role,
      lastMessageText: lastPreview?.text,
    )
  }

  private static func preview(
    fromEntryPayloadData data: Data?,
    limit: Int,
  ) -> (role: WuhuSessionSummary.MessageRole, text: String?)? {
    guard let data else { return nil }
    guard case let .message(message) = try? WuhuJSON.decoder.decode(WuhuEntryPayload.self, from: data) else {
      return nil
    }

    switch message {
    case let .assistant(message):
      return (.assistant, normalizedPreviewText(from: message.content, limit: limit))
    case let .user(message):
      return (.user, normalizedPreviewText(from: message.content, limit: limit))
    case .toolResult, .customMessage, .unknown:
      return nil
    }
  }

  private static func previewText(fromEntryPayloadData data: Data?, limit: Int) -> String? {
    preview(fromEntryPayloadData: data, limit: limit)?.text
  }

  private static func normalizedPreviewText(from blocks: [WuhuContentBlock], limit: Int) -> String? {
    let text = blocks.compactMap { block -> String? in
      if case let .text(text, _) = block { return text }
      return nil
    }
    .joined(separator: "\n")
    .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !text.isEmpty else { return nil }

    let collapsed = text
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")

    guard collapsed.count > limit else { return collapsed }
    let end = collapsed.index(collapsed.startIndex, offsetBy: max(0, limit - 1))
    return String(collapsed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }
}
