import Foundation
import GRDB
import WuhuAI
import WuhuAPI

// MARK: - Contracts State (Queues / Tool Calls / Settings)

extension SQLiteSessionStore {
  struct LoopStateParts: Sendable {
    var session: WuhuSession
    var entries: [WuhuSessionEntry]
    var toolCallStatus: [String: ToolCallStatus]
    var settings: SessionSettingsSnapshot
    var status: SessionStatusSnapshot
    var systemUrgent: SystemUrgentQueueBackfill
    var steer: UserQueueBackfill
    var followUp: UserQueueBackfill
  }

  struct ToolCallStatusUpdate: Sendable, Hashable {
    var id: String
    var status: ToolCallStatus
  }

  struct SessionMetadataUpdate: Sendable {
    var customTitle: String?
    var isArchived: Bool
    var cwd: String?
  }

  struct SystemQueueEnqueueOperation: Sendable {
    var item: SystemUrgentPendingItem
    var insertPending: Bool
  }

  struct UserQueueOperation: Sendable {
    enum Kind: Sendable {
      case enqueue(item: UserQueuePendingItem, insertPending: Bool)
      case cancel(id: QueueItemID, deletePending: Bool, createdAt: Date)
    }

    var lane: UserQueueLane
    var kind: Kind
  }

  struct TranscriptAppendOperation: Sendable {
    enum Source: Sendable {
      case systemMaterialization(id: QueueItemID, deletePending: Bool, journalCreatedAt: Date)
      case userMaterialization(lane: UserQueueLane, id: QueueItemID, deletePending: Bool, journalCreatedAt: Date)
    }

    var createdAt: Date
    var payload: WuhuEntryPayload
    var source: Source?
  }

  struct LoopPersistencePatch: Sendable {
    var pendingModelSelection: WuhuSessionSettings?
    var systemQueueEnqueues: [SystemQueueEnqueueOperation]
    var userQueueOperations: [UserQueueOperation]
    var transcriptAppends: [TranscriptAppendOperation]
    var toolCallStatusChanges: [ToolCallStatusUpdate]
    var sessionMetadata: SessionMetadataUpdate?
    var executionStatus: SessionExecutionStatus?
  }

  func loadLoopStateParts(sessionID: SessionID) async throws -> LoopStateParts {
    try await dbQueue.read { db in
      try Self.loadLoopStateParts(db: db, sessionID: sessionID)
    }
  }

  func loadSettingsSnapshot(sessionID: SessionID) async throws -> SessionSettingsSnapshot {
    try await dbQueue.read { db in
      guard let row = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw WuhuStoreError.sessionNotFound(sessionID.rawValue)
      }

      let effectiveModel = ModelSpecifier(provider: ProviderID(rawValue: row.provider), id: row.model)
      let pendingModel: ModelSpecifier? = {
        guard let p = row.pendingProvider, let m = row.pendingModel else { return nil }
        return ModelSpecifier(provider: ProviderID(rawValue: p), id: m)
      }()

      let effectiveEffort = row.effectiveReasoningEffort.flatMap(ReasoningEffort.init(rawValue:))
      let pendingEffort = row.pendingReasoningEffort.flatMap(ReasoningEffort.init(rawValue:))

      return .init(
        effectiveModel: effectiveModel,
        pendingModel: pendingModel,
        effectiveReasoningEffort: effectiveEffort,
        pendingReasoningEffort: pendingEffort,
      )
    }
  }

  func loadStatusSnapshot(sessionID: SessionID) async throws -> SessionStatusSnapshot {
    try await dbQueue.read { db in
      guard let row = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw WuhuStoreError.sessionNotFound(sessionID.rawValue)
      }
      let status = SessionExecutionStatus(rawValue: row.executionStatus) ?? .idle
      return .init(status: status)
    }
  }

  func setSessionExecutionStatus(sessionID: SessionID, status: SessionExecutionStatus) async throws {
    try await dbQueue.write { db in
      try Self.setExecutionStatus(db: db, sessionID: sessionID.rawValue, status: status)
    }
  }

  func persistLoopStatePatch(
    sessionID: SessionID,
    patch: LoopPersistencePatch,
  ) async throws -> LoopStateParts {
    try await dbQueue.write { db in
      guard var sessionRow = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw WuhuStoreError.sessionNotFound(sessionID.rawValue)
      }

      if let pendingSelection = patch.pendingModelSelection {
        try Self.setPendingModelSelection(db: db, sessionRow: &sessionRow, selection: pendingSelection)
      }

      for operation in patch.systemQueueEnqueues {
        try Self.applySystemQueueEnqueueOperation(db: db, sessionID: sessionID, operation: operation)
      }

      for operation in patch.userQueueOperations {
        try Self.applyUserQueueOperation(db: db, sessionID: sessionID, operation: operation)
      }

      for operation in patch.transcriptAppends {
        try Self.appendTranscriptOperation(
          db: db,
          sessionID: sessionID,
          sessionRow: &sessionRow,
          operation: operation,
        )
      }

      for change in patch.toolCallStatusChanges {
        try Self.setToolCallStatus(
          db: db,
          sessionID: sessionID.rawValue,
          id: change.id,
          status: change.status,
        )
      }

      if let metadata = patch.sessionMetadata {
        try Self.setSessionMetadata(db: db, sessionRow: &sessionRow, update: metadata)
      }

      if let executionStatus = patch.executionStatus {
        try Self.setExecutionStatus(db: db, sessionID: sessionID.rawValue, status: executionStatus)
      }

      return try Self.loadLoopStateParts(db: db, sessionID: sessionID)
    }
  }

  func loadSystemQueueBackfill(sessionID: SessionID) async throws -> SystemUrgentQueueBackfill {
    try await dbQueue.read { db in
      try Self.loadSystemQueueBackfill(db: db, sessionID: sessionID)
    }
  }

  func loadUserQueueBackfill(sessionID: SessionID, lane: UserQueueLane) async throws -> UserQueueBackfill {
    try await dbQueue.read { db in
      try Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: lane)
    }
  }

  func loadSystemQueueBackfill(sessionID: SessionID, since cursor: QueueCursor?) async throws -> SystemUrgentQueueBackfill {
    try await dbQueue.read { db in
      try Self.loadSystemQueueBackfill(db: db, sessionID: sessionID, since: cursor)
    }
  }

  func loadUserQueueBackfill(sessionID: SessionID, lane: UserQueueLane, since cursor: QueueCursor?) async throws -> UserQueueBackfill {
    try await dbQueue.read { db in
      try Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: lane, since: cursor)
    }
  }

  func loadSystemQueueJournal(sessionID: SessionID, since cursor: QueueCursor) async throws -> (cursor: QueueCursor, entries: [SystemUrgentQueueJournalEntry]) {
    try await dbQueue.read { db in
      try Self.loadSystemQueueJournal(db: db, sessionID: sessionID, since: cursor)
    }
  }

  func loadUserQueueJournal(sessionID: SessionID, lane: UserQueueLane, since cursor: QueueCursor) async throws -> (cursor: QueueCursor, entries: [UserQueueJournalEntry]) {
    try await dbQueue.read { db in
      try Self.loadUserQueueJournal(db: db, sessionID: sessionID, lane: lane, since: cursor)
    }
  }

  func loadToolCallStatus(sessionID: SessionID) async throws -> [String: ToolCallStatus] {
    try await dbQueue.read { db in
      let rows = try ToolCallStatusRow
        .filter(Column("sessionID") == sessionID.rawValue)
        .fetchAll(db)
      var out: [String: ToolCallStatus] = [:]
      out.reserveCapacity(rows.count)
      for r in rows {
        out[r.toolCallID] = ToolCallStatus(rawValue: r.status) ?? .pending
      }
      return out
    }
  }

  func upsertToolCallStatuses(sessionID: SessionID, calls: [ToolCall], status: ToolCallStatus) async throws -> [ToolCallStatusUpdate] {
    let now = Date()
    try await dbQueue.write { db in
      for call in calls {
        try db.execute(
          sql: """
          INSERT INTO tool_call_status (sessionID, toolCallID, status, createdAt, updatedAt)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(sessionID, toolCallID) DO UPDATE SET status = excluded.status, updatedAt = excluded.updatedAt
          """,
          arguments: [sessionID.rawValue, call.id, status.rawValue, now, now],
        )
      }
      if status == .pending || status == .started {
        try Self.setExecutionStatus(db: db, sessionID: sessionID.rawValue, status: .running)
      }
    }
    return calls.map { .init(id: $0.id, status: status) }
  }

  func setToolCallStatus(sessionID: SessionID, id: String, status: ToolCallStatus) async throws -> ToolCallStatusUpdate {
    try await dbQueue.write { db in
      try Self.setToolCallStatus(db: db, sessionID: sessionID.rawValue, id: id, status: status)
    }
    return .init(id: id, status: status)
  }

  func appendEntryWithSession(
    sessionID: SessionID,
    payload: WuhuEntryPayload,
    createdAt: Date,
    entryID: Int64? = nil,
  ) async throws -> (WuhuSession, WuhuSessionEntry) {
    try await dbQueue.write { db in
      guard var sessionRow = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw WuhuStoreError.sessionNotFound(sessionID.rawValue)
      }
      let entryRow = try Self.appendEntryWithSession(
        db: db,
        sessionRow: &sessionRow,
        payload: payload,
        createdAt: createdAt,
        entryID: entryID,
      )
      return try (sessionRow.toModel(), entryRow.toModel())
    }
  }

  func setSessionMetadata(
    sessionID: String,
    customTitle: String?,
    isArchived: Bool,
    cwd: String?,
  ) async throws -> WuhuSession {
    try await dbQueue.write { db in
      guard var sessionRow = try SessionRow.fetchOne(db, key: sessionID) else {
        throw WuhuStoreError.sessionNotFound(sessionID)
      }
      try Self.setSessionMetadata(
        db: db,
        sessionRow: &sessionRow,
        update: .init(customTitle: customTitle, isArchived: isArchived, cwd: cwd),
      )
      return try sessionRow.toModel()
    }
  }

  // MARK: - Rename

  public func renameSession(id: String, title: String) async throws -> WuhuSession {
    try await dbQueue.write { db in
      guard var row = try SessionRow.fetchOne(db, key: id) else {
        throw WuhuStoreError.sessionNotFound(id)
      }
      let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
      row.customTitle = trimmed.isEmpty ? nil : trimmed
      row.updatedAt = Date()
      try row.update(db)
      return try row.toModel()
    }
  }

  // MARK: - Archive

  public func archiveSession(id: String) async throws -> WuhuSession {
    try await dbQueue.write { db in
      guard var row = try SessionRow.fetchOne(db, key: id) else {
        throw WuhuStoreError.sessionNotFound(id)
      }
      row.isArchived = true
      row.updatedAt = Date()
      try row.update(db)
      return try row.toModel()
    }
  }

  public func unarchiveSession(id: String) async throws -> WuhuSession {
    try await dbQueue.write { db in
      guard var row = try SessionRow.fetchOne(db, key: id) else {
        throw WuhuStoreError.sessionNotFound(id)
      }
      row.isArchived = false
      row.updatedAt = Date()
      try row.update(db)
      return try row.toModel()
    }
  }

  // MARK: - Helpers (DB)

  private static func loadLoopStateParts(db: Database, sessionID: SessionID) throws -> LoopStateParts {
    guard let sessionRow = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
      throw WuhuStoreError.sessionNotFound(sessionID.rawValue)
    }

    let session = try sessionRow.toModel()
    let entryRows = try EntryRow
      .filter(Column("sessionID") == sessionID.rawValue)
      .fetchAll(db)
    let entries = try Self.linearize(
      entries: entryRows.map { $0.toModel() },
      sessionID: sessionID.rawValue,
      headEntryID: session.headEntryID,
      tailEntryID: session.tailEntryID,
    )

    let toolCallRows = try ToolCallStatusRow
      .filter(Column("sessionID") == sessionID.rawValue)
      .fetchAll(db)
    var toolCallStatus: [String: ToolCallStatus] = [:]
    toolCallStatus.reserveCapacity(toolCallRows.count)
    for row in toolCallRows {
      toolCallStatus[row.toolCallID] = ToolCallStatus(rawValue: row.status) ?? .pending
    }

    let effectiveModel = ModelSpecifier(provider: ProviderID(rawValue: sessionRow.provider), id: sessionRow.model)
    let pendingModel: ModelSpecifier? = {
      guard let provider = sessionRow.pendingProvider, let model = sessionRow.pendingModel else { return nil }
      return .init(provider: ProviderID(rawValue: provider), id: model)
    }()
    let settings = SessionSettingsSnapshot(
      effectiveModel: effectiveModel,
      pendingModel: pendingModel,
      effectiveReasoningEffort: sessionRow.effectiveReasoningEffort.flatMap(ReasoningEffort.init(rawValue:)),
      pendingReasoningEffort: sessionRow.pendingReasoningEffort.flatMap(ReasoningEffort.init(rawValue:)),
    )
    let status = SessionStatusSnapshot(
      status: SessionExecutionStatus(rawValue: sessionRow.executionStatus) ?? .idle,
    )

    return try .init(
      session: session,
      entries: entries,
      toolCallStatus: toolCallStatus,
      settings: settings,
      status: status,
      systemUrgent: loadSystemQueueBackfill(db: db, sessionID: sessionID),
      steer: loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .steer),
      followUp: loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .followUp),
    )
  }

  private static func setPendingModelSelection(
    db: Database,
    sessionRow: inout SessionRow,
    selection: WuhuSessionSettings,
  ) throws {
    sessionRow.pendingProvider = selection.provider.rawValue
    sessionRow.pendingModel = selection.model
    sessionRow.pendingReasoningEffort = selection.reasoningEffort?.rawValue
    sessionRow.updatedAt = Date()
    try sessionRow.update(db)
  }

  private static func setToolCallStatus(
    db: Database,
    sessionID: String,
    id: String,
    status: ToolCallStatus,
  ) throws {
    let now = Date()
    try db.execute(
      sql: """
      INSERT INTO tool_call_status (sessionID, toolCallID, status, createdAt, updatedAt)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(sessionID, toolCallID) DO UPDATE SET status = excluded.status, updatedAt = excluded.updatedAt
      """,
      arguments: [sessionID, id, status.rawValue, now, now],
    )
    if status == .pending || status == .started {
      try setExecutionStatus(db: db, sessionID: sessionID, status: .running)
    }
  }

  private static func setSessionMetadata(
    db: Database,
    sessionRow: inout SessionRow,
    update: SessionMetadataUpdate,
  ) throws {
    sessionRow.customTitle = update.customTitle
    sessionRow.isArchived = update.isArchived
    sessionRow.cwd = update.cwd
    sessionRow.updatedAt = Date()
    try sessionRow.update(db)
  }

  private static func applySystemQueueEnqueueOperation(
    db: Database,
    sessionID: SessionID,
    operation: SystemQueueEnqueueOperation,
  ) throws {
    if operation.insertPending {
      let data = try WuhuJSON.encoder.encode(operation.item.input)
      try db.execute(
        sql: "INSERT INTO system_queue_pending (id, sessionID, enqueuedAt, payload) VALUES (?, ?, ?, ?)",
        arguments: [operation.item.id.rawValue, sessionID.rawValue, operation.item.enqueuedAt, data],
      )
    }

    let journal = SystemUrgentQueueJournalEntry.enqueued(item: operation.item)
    let journalData = try WuhuJSON.encoder.encode(journal)
    try db.execute(
      sql: "INSERT INTO system_queue_journal (sessionID, payload, createdAt) VALUES (?, ?, ?)",
      arguments: [sessionID.rawValue, journalData, operation.item.enqueuedAt],
    )

    try updateSessionUpdatedAt(db: db, sessionID: sessionID.rawValue)
    try setExecutionStatus(db: db, sessionID: sessionID.rawValue, status: .running)
  }

  private static func applyUserQueueOperation(
    db: Database,
    sessionID: SessionID,
    operation: UserQueueOperation,
  ) throws {
    switch operation.kind {
    case let .enqueue(item, insertPending):
      if insertPending {
        let data = try WuhuJSON.encoder.encode(item.message)
        try db.execute(
          sql: """
          INSERT INTO user_queue_pending (id, sessionID, lane, enqueuedAt, payload)
          VALUES (?, ?, ?, ?, ?)
          """,
          arguments: [item.id.rawValue, sessionID.rawValue, operation.lane.rawValue, item.enqueuedAt, data],
        )
      }

      let journal = UserQueueJournalEntry.enqueued(lane: operation.lane, item: item)
      let journalData = try WuhuJSON.encoder.encode(journal)
      try db.execute(
        sql: """
        INSERT INTO user_queue_journal (sessionID, lane, payload, createdAt)
        VALUES (?, ?, ?, ?)
        """,
        arguments: [sessionID.rawValue, operation.lane.rawValue, journalData, item.enqueuedAt],
      )

      try updateSessionUpdatedAt(db: db, sessionID: sessionID.rawValue)
      try setExecutionStatus(db: db, sessionID: sessionID.rawValue, status: .running)

    case let .cancel(id, deletePending, createdAt):
      if deletePending {
        try db.execute(
          sql: "DELETE FROM user_queue_pending WHERE sessionID = ? AND lane = ? AND id = ?",
          arguments: [sessionID.rawValue, operation.lane.rawValue, id.rawValue],
        )
        if db.changesCount == 0 {
          throw WuhuStoreError.sessionCorrupt("Queue item not found: \(id.rawValue)")
        }
      }

      let journal = UserQueueJournalEntry.canceled(lane: operation.lane, id: id, at: createdAt)
      let journalData = try WuhuJSON.encoder.encode(journal)
      try db.execute(
        sql: "INSERT INTO user_queue_journal (sessionID, lane, payload, createdAt) VALUES (?, ?, ?, ?)",
        arguments: [sessionID.rawValue, operation.lane.rawValue, journalData, createdAt],
      )

      try updateSessionUpdatedAt(db: db, sessionID: sessionID.rawValue)
      try maybeSetIdleIfNoPendingWork(db: db, sessionID: sessionID.rawValue)
    }
  }

  private static func appendTranscriptOperation(
    db: Database,
    sessionID: SessionID,
    sessionRow: inout SessionRow,
    operation: TranscriptAppendOperation,
  ) throws {
    let entryRow = try appendEntryWithSession(
      db: db,
      sessionRow: &sessionRow,
      payload: operation.payload,
      createdAt: operation.createdAt,
      entryID: nil,
    )

    guard let entryID = entryRow.id else {
      throw WuhuStoreError.sessionCorrupt("Failed to create entry id")
    }

    guard let source = operation.source else { return }
    let transcriptEntryID = TranscriptEntryID(rawValue: "\(entryID)")

    switch source {
    case let .systemMaterialization(id, deletePending, journalCreatedAt):
      if deletePending {
        try db.execute(
          sql: "DELETE FROM system_queue_pending WHERE sessionID = ? AND id = ?",
          arguments: [sessionID.rawValue, id.rawValue],
        )
        if db.changesCount == 0 {
          throw WuhuStoreError.sessionCorrupt("Queue item not found: \(id.rawValue)")
        }
      }

      let journal = SystemUrgentQueueJournalEntry.materialized(
        id: id,
        transcriptEntryID: transcriptEntryID,
        at: journalCreatedAt,
      )
      let data = try WuhuJSON.encoder.encode(journal)
      try db.execute(
        sql: "INSERT INTO system_queue_journal (sessionID, payload, createdAt) VALUES (?, ?, ?)",
        arguments: [sessionID.rawValue, data, journalCreatedAt],
      )

    case let .userMaterialization(lane, id, deletePending, journalCreatedAt):
      if deletePending {
        try db.execute(
          sql: "DELETE FROM user_queue_pending WHERE sessionID = ? AND lane = ? AND id = ?",
          arguments: [sessionID.rawValue, lane.rawValue, id.rawValue],
        )
        if db.changesCount == 0 {
          throw WuhuStoreError.sessionCorrupt("Queue item not found: \(id.rawValue)")
        }
      }

      let journal = UserQueueJournalEntry.materialized(
        lane: lane,
        id: id,
        transcriptEntryID: transcriptEntryID,
        at: journalCreatedAt,
      )
      let data = try WuhuJSON.encoder.encode(journal)
      try db.execute(
        sql: "INSERT INTO user_queue_journal (sessionID, lane, payload, createdAt) VALUES (?, ?, ?, ?)",
        arguments: [sessionID.rawValue, lane.rawValue, data, journalCreatedAt],
      )
    }
  }

  private static func updateSessionUpdatedAt(db: Database, sessionID: String) throws {
    try db.execute(
      sql: "UPDATE sessions SET updatedAt = ? WHERE id = ?",
      arguments: [Date(), sessionID],
    )
  }

  private static func setExecutionStatus(db: Database, sessionID: String, status: SessionExecutionStatus) throws {
    try db.execute(
      sql: "UPDATE sessions SET executionStatus = ?, updatedAt = ? WHERE id = ?",
      arguments: [status.rawValue, Date(), sessionID],
    )
  }

  private static func maybeSetIdleIfNoPendingWork(db: Database, sessionID: String) throws {
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

  private static func pendingWorkCount(db: Database, sessionID: String) throws -> Int {
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

  private static func loadSystemQueueBackfill(db: Database, sessionID: SessionID) throws -> SystemUrgentQueueBackfill {
    try loadSystemQueueBackfill(db: db, sessionID: sessionID, since: nil)
  }

  private static func loadSystemQueueBackfill(db: Database, sessionID: SessionID, since cursor: QueueCursor?) throws -> SystemUrgentQueueBackfill {
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

  private static func loadSystemQueueJournal(
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

  private static func loadUserQueueBackfill(db: Database, sessionID: SessionID, lane: UserQueueLane) throws -> UserQueueBackfill {
    try loadUserQueueBackfill(db: db, sessionID: sessionID, lane: lane, since: nil)
  }

  private static func loadUserQueueBackfill(db: Database, sessionID: SessionID, lane: UserQueueLane, since cursor: QueueCursor?) throws -> UserQueueBackfill {
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

  private static func loadUserQueueJournal(
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

  private static func appendEntryWithSession(
    db: Database,
    sessionRow: inout SessionRow,
    payload: WuhuEntryPayload,
    createdAt: Date,
    entryID: Int64? = nil,
  ) throws -> EntryRow {
    let tailID = sessionRow.tailEntryID

    var row = try EntryRow.new(
      id: entryID,
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
