import Foundation
import GRDB
import PiAI
import WuhuAPI

// MARK: - Row types

struct MountTemplateRow: Codable, FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "mount_templates"

  var id: String
  var name: String
  var type: String
  var templatePath: String
  var workspacesPath: String
  var startupScript: String?
  var createdAt: Date
  var updatedAt: Date

  func toModel() throws -> WuhuMountTemplate {
    guard let mtType = WuhuMountTemplateType(rawValue: type) else {
      throw WuhuMountTemplateResolutionError.unsupportedType(type)
    }
    return .init(
      id: id,
      name: name,
      type: mtType,
      templatePath: templatePath,
      workspacesPath: workspacesPath,
      startupScript: startupScript,
      createdAt: createdAt,
      updatedAt: updatedAt,
    )
  }
}

struct MountRow: Codable, FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "mounts"

  var id: String
  var sessionID: String
  var name: String
  var path: String
  var mountTemplateID: String?
  var isPrimary: Bool
  var runnerID: String
  var createdAt: Date

  func toModel() -> WuhuMount {
    let runner: RunnerID = if runnerID == "local" {
      .local
    } else if runnerID.hasPrefix("remote:") {
      .remote(name: String(runnerID.dropFirst("remote:".count)))
    } else {
      .local
    }
    return .init(
      id: id,
      sessionID: sessionID,
      name: name,
      path: path,
      mountTemplateID: mountTemplateID,
      isPrimary: isPrimary,
      runnerID: runner,
      createdAt: createdAt,
    )
  }
}

struct SessionRow: Codable, FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "sessions"

  var id: String
  var provider: String
  var model: String
  var effectiveReasoningEffort: String?
  var pendingProvider: String?
  var pendingModel: String?
  var pendingReasoningEffort: String?
  var executionStatus: String
  var cwd: String?
  var parentSessionID: String?
  var customTitle: String?
  var isArchived: Bool
  var createdAt: Date
  var updatedAt: Date
  var headEntryID: Int64?
  var tailEntryID: Int64?
  var costLimitCents: Int64?

  func toModel() throws -> WuhuSession {
    guard let provider = WuhuProvider(rawValue: provider) else {
      throw WuhuStoreError.sessionCorrupt("Unknown provider: \(self.provider)")
    }
    guard let headEntryID, let tailEntryID else {
      throw WuhuStoreError.sessionCorrupt("Session \(id) missing head/tail entry ids")
    }
    return .init(
      id: id,
      provider: provider,
      model: model,
      cwd: cwd,
      parentSessionID: parentSessionID,
      customTitle: customTitle,
      isArchived: isArchived,
      createdAt: createdAt,
      updatedAt: updatedAt,
      headEntryID: headEntryID,
      tailEntryID: tailEntryID,
    )
  }
}

struct EntryRow: Codable, FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "session_entries"

  var id: Int64?
  var sessionID: String
  var parentEntryID: Int64?
  var type: String
  var payload: Data
  var createdAt: Date

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }

  static func new(
    sessionID: String,
    parentEntryID: Int64?,
    payload: WuhuEntryPayload,
    createdAt: Date,
  ) throws -> EntryRow {
    let encoded = try WuhuJSON.encoder.encode(payload)
    return .init(
      id: nil,
      sessionID: sessionID,
      parentEntryID: parentEntryID,
      type: payload.typeString,
      payload: encoded,
      createdAt: createdAt,
    )
  }

  func toModel() -> WuhuSessionEntry {
    let decoded: WuhuEntryPayload = Self.decodePayload(type: type, data: payload)
    return .init(
      id: id ?? -1,
      sessionID: sessionID,
      parentEntryID: parentEntryID,
      createdAt: createdAt,
      payload: decoded,
    )
  }

  private static func decodePayload(type: String, data: Data) -> WuhuEntryPayload {
    if let payload = try? WuhuJSON.decoder.decode(WuhuEntryPayload.self, from: data) {
      return payload
    }
    if let json = try? WuhuJSON.decoder.decode(JSONValue.self, from: data) {
      return .unknown(type: type, payload: json)
    }
    return .unknown(type: type, payload: .null)
  }
}

struct ToolCallStatusRow: Codable, FetchableRecord, TableRecord {
  static let databaseTableName = "tool_call_status"
  var sessionID: String
  var toolCallID: String
  var status: String
  var createdAt: Date
  var updatedAt: Date
}

struct UserQueuePendingRow: Codable, FetchableRecord, TableRecord {
  static let databaseTableName = "user_queue_pending"
  var id: String
  var sessionID: String
  var lane: String
  var enqueuedAt: Date
  var payload: Data
}

struct UserQueueJournalRow: Codable, FetchableRecord, TableRecord {
  static let databaseTableName = "user_queue_journal"
  var id: Int64
  var sessionID: String
  var lane: String
  var payload: Data
  var createdAt: Date
}

struct SystemQueuePendingRow: Codable, FetchableRecord, TableRecord {
  static let databaseTableName = "system_queue_pending"
  var id: String
  var sessionID: String
  var enqueuedAt: Date
  var payload: Data
}

struct SystemQueueJournalRow: Codable, FetchableRecord, TableRecord {
  static let databaseTableName = "system_queue_journal"
  var id: Int64
  var sessionID: String
  var payload: Data
  var createdAt: Date
}

// MARK: - Helpers (DB)

extension SQLiteSessionStore {
  static func updateSessionUpdatedAt(db: Database, sessionID: String) throws {
    try db.execute(
      sql: "UPDATE sessions SET updatedAt = ? WHERE id = ?",
      arguments: [Date(), sessionID],
    )
  }

  static func setExecutionStatus(db: Database, sessionID: String, status: SessionExecutionStatus) throws {
    try db.execute(
      sql: "UPDATE sessions SET executionStatus = ?, updatedAt = ? WHERE id = ?",
      arguments: [status.rawValue, Date(), sessionID],
    )
  }

  static func maybeSetIdleIfNoPendingWork(db: Database, sessionID: String) throws {
    guard let row = try SessionRow.fetchOne(db, key: sessionID) else {
      throw WuhuStoreError.sessionNotFound(sessionID)
    }
    if row.executionStatus == SessionExecutionStatus.stopped.rawValue {
      return
    }
    let pending = try pendingWorkCount(db: db, sessionID: sessionID)
    if pending == 0 {
      try setExecutionStatus(db: db, sessionID: sessionID, status: .idle)
    }
  }

  static func pendingWorkCount(db: Database, sessionID: String) throws -> Int {
    let systemCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM system_queue_pending WHERE sessionID = ?", arguments: [sessionID]) ?? 0
    let userCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user_queue_pending WHERE sessionID = ?", arguments: [sessionID]) ?? 0
    let toolCount = try Int.fetchOne(
      db,
      sql: """
      SELECT COUNT(*) FROM tool_call_status
      WHERE sessionID = ? AND (status = ? OR status = ?)
      """,
      arguments: [sessionID, ToolCallStatus.pending.rawValue, ToolCallStatus.started.rawValue],
    ) ?? 0
    return systemCount + userCount + toolCount
  }

  static func loadSystemQueueBackfill(db: Database, sessionID: SessionID) throws -> SystemUrgentQueueBackfill {
    try loadSystemQueueBackfill(db: db, sessionID: sessionID, since: nil)
  }

  static func loadSystemQueueBackfill(db: Database, sessionID: SessionID, since cursor: QueueCursor?) throws -> SystemUrgentQueueBackfill {
    let pendingRows = try SystemQueuePendingRow
      .filter(Column("sessionID") == sessionID.rawValue)
      .order(Column("enqueuedAt").asc)
      .fetchAll(db)
    let pending: [SystemUrgentPendingItem] = try pendingRows.map { row in
      let input = try WuhuJSON.decoder.decode(SystemUrgentInput.self, from: row.payload)
      return .init(id: QueueItemID(rawValue: row.id), enqueuedAt: row.enqueuedAt, input: input)
    }

    let sinceID = Int64(cursor?.rawValue ?? "") ?? 0
    let maxID = try Int64.fetchOne(
      db,
      sql: "SELECT MAX(id) FROM system_queue_journal WHERE sessionID = ?",
      arguments: [sessionID.rawValue],
    ) ?? 0
    let effectiveMax = max(maxID, sinceID)

    let journalRows = try SystemQueueJournalRow
      .filter(Column("sessionID") == sessionID.rawValue && Column("id") > sinceID)
      .order(Column("id").asc)
      .fetchAll(db)
    let journal: [SystemUrgentQueueJournalEntry] = try journalRows.map { row in
      try WuhuJSON.decoder.decode(SystemUrgentQueueJournalEntry.self, from: row.payload)
    }

    return .init(cursor: .init(rawValue: "\(effectiveMax)"), pending: pending, journal: journal)
  }

  static func loadSystemQueueJournal(
    db: Database,
    sessionID: SessionID,
    since cursor: QueueCursor,
  ) throws -> (cursor: QueueCursor, entries: [SystemUrgentQueueJournalEntry]) {
    let sinceID = Int64(cursor.rawValue) ?? 0
    let maxID = try Int64.fetchOne(
      db,
      sql: "SELECT MAX(id) FROM system_queue_journal WHERE sessionID = ?",
      arguments: [sessionID.rawValue],
    ) ?? 0
    let effectiveMax = max(maxID, sinceID)

    let journalRows = try SystemQueueJournalRow
      .filter(Column("sessionID") == sessionID.rawValue && Column("id") > sinceID)
      .order(Column("id").asc)
      .fetchAll(db)
    let entries: [SystemUrgentQueueJournalEntry] = try journalRows.map { row in
      try WuhuJSON.decoder.decode(SystemUrgentQueueJournalEntry.self, from: row.payload)
    }

    return (cursor: .init(rawValue: "\(effectiveMax)"), entries: entries)
  }

  static func loadUserQueueBackfill(db: Database, sessionID: SessionID, lane: UserQueueLane) throws -> UserQueueBackfill {
    try loadUserQueueBackfill(db: db, sessionID: sessionID, lane: lane, since: nil)
  }

  static func loadUserQueueBackfill(db: Database, sessionID: SessionID, lane: UserQueueLane, since cursor: QueueCursor?) throws -> UserQueueBackfill {
    let pendingRows = try UserQueuePendingRow
      .filter(Column("sessionID") == sessionID.rawValue && Column("lane") == lane.rawValue)
      .order(Column("enqueuedAt").asc)
      .fetchAll(db)
    let pending: [UserQueuePendingItem] = try pendingRows.map { row in
      let message = try WuhuJSON.decoder.decode(QueuedUserMessage.self, from: row.payload)
      return .init(id: QueueItemID(rawValue: row.id), enqueuedAt: row.enqueuedAt, message: message)
    }

    let sinceID = Int64(cursor?.rawValue ?? "") ?? 0
    let maxID = try Int64.fetchOne(
      db,
      sql: "SELECT MAX(id) FROM user_queue_journal WHERE sessionID = ? AND lane = ?",
      arguments: [sessionID.rawValue, lane.rawValue],
    ) ?? 0
    let effectiveMax = max(maxID, sinceID)

    let journalRows = try UserQueueJournalRow
      .filter(Column("sessionID") == sessionID.rawValue && Column("lane") == lane.rawValue && Column("id") > sinceID)
      .order(Column("id").asc)
      .fetchAll(db)
    let journal: [UserQueueJournalEntry] = try journalRows.map { row in
      try WuhuJSON.decoder.decode(UserQueueJournalEntry.self, from: row.payload)
    }

    return .init(cursor: .init(rawValue: "\(effectiveMax)"), pending: pending, journal: journal)
  }

  static func loadUserQueueJournal(
    db: Database,
    sessionID: SessionID,
    lane: UserQueueLane,
    since cursor: QueueCursor,
  ) throws -> (cursor: QueueCursor, entries: [UserQueueJournalEntry]) {
    let sinceID = Int64(cursor.rawValue) ?? 0
    let maxID = try Int64.fetchOne(
      db,
      sql: "SELECT MAX(id) FROM user_queue_journal WHERE sessionID = ? AND lane = ?",
      arguments: [sessionID.rawValue, lane.rawValue],
    ) ?? 0
    let effectiveMax = max(maxID, sinceID)

    let journalRows = try UserQueueJournalRow
      .filter(Column("sessionID") == sessionID.rawValue && Column("lane") == lane.rawValue && Column("id") > sinceID)
      .order(Column("id").asc)
      .fetchAll(db)
    let entries: [UserQueueJournalEntry] = try journalRows.map { row in
      try WuhuJSON.decoder.decode(UserQueueJournalEntry.self, from: row.payload)
    }

    return (cursor: .init(rawValue: "\(effectiveMax)"), entries: entries)
  }

  static func appendEntryWithSession(db: Database, sessionRow: inout SessionRow, payload: WuhuEntryPayload, createdAt: Date) throws -> EntryRow {
    let tailID = sessionRow.tailEntryID

    var row = try EntryRow.new(
      sessionID: sessionRow.id,
      parentEntryID: tailID,
      payload: payload,
      createdAt: createdAt,
    )
    try row.insert(db)
    guard let newID = row.id else {
      throw WuhuStoreError.sessionCorrupt("Failed to create entry id")
    }

    sessionRow.tailEntryID = newID
    sessionRow.updatedAt = Date()

    if case let .sessionSettings(settings) = payload {
      sessionRow.provider = settings.provider.rawValue
      sessionRow.model = settings.model
      sessionRow.effectiveReasoningEffort = settings.reasoningEffort?.rawValue
      sessionRow.pendingProvider = nil
      sessionRow.pendingModel = nil
      sessionRow.pendingReasoningEffort = nil
    }

    try sessionRow.update(db)

    if case let .message(message) = payload,
       case let .assistant(assistant) = message
    {
      let hasToolCalls = assistant.content.contains { block in
        if case .toolCall = block { return true }
        return false
      }
      if hasToolCalls {
        try setExecutionStatus(db: db, sessionID: sessionRow.id, status: .running)
      } else {
        try maybeSetIdleIfNoPendingWork(db: db, sessionID: sessionRow.id)
      }
    }

    if case let .message(message) = payload,
       case .toolResult = message
    {
      try setExecutionStatus(db: db, sessionID: sessionRow.id, status: .running)
    }

    guard let fetched = try EntryRow.fetchOne(db, key: newID) else {
      throw WuhuStoreError.sessionCorrupt("Failed to re-fetch inserted entry \(newID)")
    }
    return fetched
  }
}

// MARK: - Free functions

func userString(_ author: Author) -> String {
  switch author {
  case .system:
    "system"
  case let .participant(id, _):
    id.rawValue
  case .unknown:
    WuhuUserMessage.unknownUser
  }
}

func systemSourceString(_ source: SystemUrgentSource) -> String {
  switch source {
  case .asyncBashCallback:
    "asyncBashCallback"
  case .asyncTaskNotification:
    "asyncTaskNotification"
  case let .other(s):
    s
  }
}
