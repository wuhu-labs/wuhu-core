import Foundation
import GRDB
import PiAI
import WuhuAPI

// MARK: - Contracts State (Queues / Tool Calls / Settings)

extension SQLiteSessionStore {
  struct LoopStateParts: Sendable {
    var session: WuhuSession
    var entries: [WuhuSessionEntry]
    var toolCallStatus: [String: ToolCallRecord]
    var settings: SessionSettingsSnapshot
    var status: SessionStatusSnapshot
    var systemUrgent: SystemUrgentQueueBackfill
    var steer: UserQueueBackfill
    var followUp: UserQueueBackfill
    var costLimitCents: Int64?
  }

  struct DrainResult: Sendable {
    var didDrain: Bool
    var session: WuhuSession
    var entries: [WuhuSessionEntry]
    var systemUrgent: SystemUrgentQueueBackfill
    var steer: UserQueueBackfill
    var followUp: UserQueueBackfill
  }

  struct ToolCallStatusUpdate: Sendable, Hashable {
    var id: String
    var status: ToolCallStatus
  }

  func loadLoopStateParts(sessionID: SessionID) async throws -> LoopStateParts {
    let session = try await getSession(id: sessionID.rawValue)
    let costLimitCents = try await loadCostLimitCents(sessionID: sessionID)
    let entries = try await getEntries(sessionID: sessionID.rawValue)
    let toolCallStatus = try await loadToolCallStatus(sessionID: sessionID)
    let settings = try await loadSettingsSnapshot(sessionID: sessionID)
    let status = try await loadStatusSnapshot(sessionID: sessionID)
    let systemUrgent = try await loadSystemQueueBackfill(sessionID: sessionID)
    let steer = try await loadUserQueueBackfill(sessionID: sessionID, lane: .steer)
    let followUp = try await loadUserQueueBackfill(sessionID: sessionID, lane: .followUp)
    return .init(
      session: session,
      entries: entries,
      toolCallStatus: toolCallStatus,
      settings: settings,
      status: status,
      systemUrgent: systemUrgent,
      steer: steer,
      followUp: followUp,
      costLimitCents: costLimitCents,
    )
  }

  func loadCostLimitCents(sessionID: SessionID) async throws -> Int64? {
    try await dbQueue.read { db in
      guard let row = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw StoreError.sessionNotFound(sessionID.rawValue)
      }
      return row.costLimitCents
    }
  }

  func setCostLimitCents(sessionID: SessionID, costLimitCents: Int64?) async throws {
    try await dbQueue.write { db in
      guard var row = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw StoreError.sessionNotFound(sessionID.rawValue)
      }
      row.costLimitCents = costLimitCents
      row.updatedAt = Date()
      try row.update(db)
    }
  }

  func queryRecentlyRunningSessions() async throws -> [WuhuSession] {
    try await dbQueue.read { db in
      let cutoff = Date().addingTimeInterval(-24 * 3600)
      return try SessionRow
        .filter(Column("executionStatus") == SessionExecutionStatus.running.rawValue)
        .filter(Column("isArchived") == false)
        .filter(Column("updatedAt") > cutoff)
        .fetchAll(db)
        .map { try $0.toModel() }
    }
  }

  func loadSettingsSnapshot(sessionID: SessionID) async throws -> SessionSettingsSnapshot {
    try await dbQueue.read { db in
      guard let row = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw StoreError.sessionNotFound(sessionID.rawValue)
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
        throw StoreError.sessionNotFound(sessionID.rawValue)
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

  func setPendingModelSelection(sessionID: SessionID, selection: WuhuSessionSettings) async throws -> SessionSettingsSnapshot {
    try await dbQueue.write { db in
      guard var row = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw StoreError.sessionNotFound(sessionID.rawValue)
      }
      row.pendingProvider = selection.provider.rawValue
      row.pendingModel = selection.model
      row.pendingReasoningEffort = selection.reasoningEffort?.rawValue
      row.updatedAt = Date()
      try row.update(db)
    }
    return try await loadSettingsSnapshot(sessionID: sessionID)
  }

  func applyModelSelection(sessionID: SessionID, selection: WuhuSessionSettings) async throws -> (session: WuhuSession, entry: WuhuSessionEntry, settings: SessionSettingsSnapshot) {
    let (session, entry) = try await appendEntryWithSession(
      sessionID: sessionID,
      payload: .sessionSettings(selection),
      createdAt: Date(),
    )
    let settings = try await loadSettingsSnapshot(sessionID: sessionID)
    return (session, entry, settings)
  }

  func applyPendingModelIfPossible(sessionID: SessionID) async throws -> (session: WuhuSession, entry: WuhuSessionEntry, settings: SessionSettingsSnapshot)? {
    let result: (WuhuSession, WuhuSessionEntry)? = try await dbQueue.write { db in
      guard var row = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw StoreError.sessionNotFound(sessionID.rawValue)
      }
      guard let p = row.pendingProvider, let m = row.pendingModel else { return nil }

      // Only apply when no other work is pending.
      guard row.executionStatus == SessionExecutionStatus.idle.rawValue else { return nil }
      guard try Self.pendingWorkCount(db: db, sessionID: sessionID.rawValue) == 0 else { return nil }

      let provider = WuhuProvider(rawValue: p) ?? .openai
      let selection = WuhuSessionSettings(provider: provider, model: m, reasoningEffort: row.pendingReasoningEffort.flatMap(ReasoningEffort.init(rawValue:)))

      let entryRow = try Self.appendEntryWithSession(db: db, sessionRow: &row, payload: .sessionSettings(selection), createdAt: Date())
      return try (row.toModel(), entryRow.toModel())
    }

    guard let result else { return nil }
    return try await (result.0, result.1, loadSettingsSnapshot(sessionID: sessionID))
  }

  func enqueueUserMessage(sessionID: SessionID, id: QueueItemID, message: QueuedUserMessage, lane: UserQueueLane) async throws -> QueueItemID {
    let now = Date()
    try await dbQueue.write { db in
      let data = try WuhuJSON.encoder.encode(message)
      try db.execute(
        sql: """
        INSERT INTO user_queue_pending (id, sessionID, lane, enqueuedAt, payload)
        VALUES (?, ?, ?, ?, ?)
        """,
        arguments: [id.rawValue, sessionID.rawValue, lane.rawValue, now, data],
      )

      let pendingItem = UserQueuePendingItem(id: id, enqueuedAt: now, message: message)
      let journal = UserQueueJournalEntry.enqueued(lane: lane, item: pendingItem)
      let journalData = try WuhuJSON.encoder.encode(journal)
      try db.execute(
        sql: """
        INSERT INTO user_queue_journal (sessionID, lane, payload, createdAt)
        VALUES (?, ?, ?, ?)
        """,
        arguments: [sessionID.rawValue, lane.rawValue, journalData, now],
      )

      try Self.updateSessionUpdatedAt(db: db, sessionID: sessionID.rawValue)
      try Self.setExecutionStatus(db: db, sessionID: sessionID.rawValue, status: .running)
    }
    return id
  }

  func cancelUserMessage(sessionID: SessionID, id: QueueItemID, lane: UserQueueLane) async throws {
    let now = Date()
    try await dbQueue.write { db in
      try db.execute(
        sql: "DELETE FROM user_queue_pending WHERE sessionID = ? AND lane = ? AND id = ?",
        arguments: [sessionID.rawValue, lane.rawValue, id.rawValue],
      )
      if db.changesCount == 0 {
        throw StoreError.sessionCorrupt("Queue item not found: \(id.rawValue)")
      }

      let journal = UserQueueJournalEntry.canceled(lane: lane, id: id, at: now)
      let data = try WuhuJSON.encoder.encode(journal)
      try db.execute(
        sql: "INSERT INTO user_queue_journal (sessionID, lane, payload, createdAt) VALUES (?, ?, ?, ?)",
        arguments: [sessionID.rawValue, lane.rawValue, data, now],
      )

      try Self.updateSessionUpdatedAt(db: db, sessionID: sessionID.rawValue)
      try Self.maybeSetIdleIfNoPendingWork(db: db, sessionID: sessionID.rawValue)
    }
  }

  func enqueueSystemInput(sessionID: SessionID, id: QueueItemID, input: SystemUrgentInput, enqueuedAt: Date) async throws -> QueueItemID {
    let now = enqueuedAt
    try await dbQueue.write { db in
      let data = try WuhuJSON.encoder.encode(input)
      try db.execute(
        sql: "INSERT INTO system_queue_pending (id, sessionID, enqueuedAt, payload) VALUES (?, ?, ?, ?)",
        arguments: [id.rawValue, sessionID.rawValue, now, data],
      )

      let pendingItem = SystemUrgentPendingItem(id: id, enqueuedAt: now, input: input)
      let journal = SystemUrgentQueueJournalEntry.enqueued(item: pendingItem)
      let journalData = try WuhuJSON.encoder.encode(journal)
      try db.execute(
        sql: "INSERT INTO system_queue_journal (sessionID, payload, createdAt) VALUES (?, ?, ?)",
        arguments: [sessionID.rawValue, journalData, now],
      )

      try Self.updateSessionUpdatedAt(db: db, sessionID: sessionID.rawValue)
      try Self.setExecutionStatus(db: db, sessionID: sessionID.rawValue, status: .running)
    }
    return id
  }

  func drainInterruptCheckpoint(sessionID: SessionID) async throws -> DrainResult {
    try await dbQueue.write { db in
      guard var sessionRow = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw StoreError.sessionNotFound(sessionID.rawValue)
      }

      let systemRows = try SystemQueuePendingRow
        .filter(Column("sessionID") == sessionID.rawValue)
        .fetchAll(db)
      let steerRows = try UserQueuePendingRow
        .filter(Column("sessionID") == sessionID.rawValue && Column("lane") == UserQueueLane.steer.rawValue)
        .fetchAll(db)

      struct Candidate {
        var enqueuedAt: Date
        var kind: String
        var id: String
        var payload: Data
      }

      var candidates: [Candidate] = []
      candidates.reserveCapacity(systemRows.count + steerRows.count)
      for r in systemRows {
        candidates.append(.init(enqueuedAt: r.enqueuedAt, kind: "system", id: r.id, payload: r.payload))
      }
      for r in steerRows {
        candidates.append(.init(enqueuedAt: r.enqueuedAt, kind: "steer", id: r.id, payload: r.payload))
      }
      candidates.sort { a, b in
        if a.enqueuedAt != b.enqueuedAt { return a.enqueuedAt < b.enqueuedAt }
        return a.id < b.id
      }

      guard !candidates.isEmpty else {
        let session = try sessionRow.toModel()
        return try DrainResult(
          didDrain: false,
          session: session,
          entries: [],
          systemUrgent: Self.loadSystemQueueBackfill(db: db, sessionID: sessionID),
          steer: Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .steer),
          followUp: Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .followUp),
        )
      }

      var appended: [WuhuSessionEntry] = []
      appended.reserveCapacity(candidates.count)

      for c in candidates {
        let entryPayload: WuhuEntryPayload
        let createdAt = c.enqueuedAt

        if c.kind == "system" {
          let input = try WuhuJSON.decoder.decode(SystemUrgentInput.self, from: c.payload)
          let custom = WuhuCustomMessage(
            customType: WuhuCustomMessageTypes.systemInput,
            content: input.content.toContentBlocks(),
            details: .object([
              "source": .string(systemSourceString(input.source)),
            ]),
            display: true,
            timestamp: createdAt,
          )
          entryPayload = .message(.customMessage(custom))

          try db.execute(
            sql: "DELETE FROM system_queue_pending WHERE sessionID = ? AND id = ?",
            arguments: [sessionID.rawValue, c.id],
          )
        } else {
          let message = try WuhuJSON.decoder.decode(QueuedUserMessage.self, from: c.payload)
          let user = WuhuUserMessage(
            user: userString(message.author),
            content: message.content.toContentBlocks(),
            timestamp: createdAt,
          )
          entryPayload = .message(.user(user))

          try db.execute(
            sql: "DELETE FROM user_queue_pending WHERE sessionID = ? AND lane = ? AND id = ?",
            arguments: [sessionID.rawValue, UserQueueLane.steer.rawValue, c.id],
          )
        }

        let entryRow = try Self.appendEntryWithSession(db: db, sessionRow: &sessionRow, payload: entryPayload, createdAt: createdAt)
        appended.append(entryRow.toModel())

        let transcriptEntryID = TranscriptEntryID(rawValue: "\(entryRow.id ?? -1)")
        let now = Date()

        if c.kind == "system" {
          let journal = SystemUrgentQueueJournalEntry.materialized(
            id: QueueItemID(rawValue: c.id),
            transcriptEntryID: transcriptEntryID,
            at: now,
          )
          let data = try WuhuJSON.encoder.encode(journal)
          try db.execute(
            sql: "INSERT INTO system_queue_journal (sessionID, payload, createdAt) VALUES (?, ?, ?)",
            arguments: [sessionID.rawValue, data, now],
          )
        } else {
          let journal = UserQueueJournalEntry.materialized(
            lane: .steer,
            id: QueueItemID(rawValue: c.id),
            transcriptEntryID: transcriptEntryID,
            at: now,
          )
          let data = try WuhuJSON.encoder.encode(journal)
          try db.execute(
            sql: "INSERT INTO user_queue_journal (sessionID, lane, payload, createdAt) VALUES (?, ?, ?, ?)",
            arguments: [sessionID.rawValue, UserQueueLane.steer.rawValue, data, now],
          )
        }
      }

      let session = try sessionRow.toModel()
      return try DrainResult(
        didDrain: true,
        session: session,
        entries: appended,
        systemUrgent: Self.loadSystemQueueBackfill(db: db, sessionID: sessionID),
        steer: Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .steer),
        followUp: Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .followUp),
      )
    }
  }

  func drainTurnBoundary(sessionID: SessionID) async throws -> DrainResult {
    try await dbQueue.write { db in
      guard var sessionRow = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw StoreError.sessionNotFound(sessionID.rawValue)
      }

      let followRows = try UserQueuePendingRow
        .filter(Column("sessionID") == sessionID.rawValue && Column("lane") == UserQueueLane.followUp.rawValue)
        .order(Column("enqueuedAt").asc)
        .fetchAll(db)

      guard !followRows.isEmpty else {
        let session = try sessionRow.toModel()
        return try DrainResult(
          didDrain: false,
          session: session,
          entries: [],
          systemUrgent: Self.loadSystemQueueBackfill(db: db, sessionID: sessionID),
          steer: Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .steer),
          followUp: Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .followUp),
        )
      }

      var appended: [WuhuSessionEntry] = []
      appended.reserveCapacity(followRows.count)

      for r in followRows {
        let message = try WuhuJSON.decoder.decode(QueuedUserMessage.self, from: r.payload)

        let user = WuhuUserMessage(
          user: userString(message.author),
          content: message.content.toContentBlocks(),
          timestamp: r.enqueuedAt,
        )

        let entryPayload: WuhuEntryPayload = .message(.user(user))
        let entryRow = try Self.appendEntryWithSession(db: db, sessionRow: &sessionRow, payload: entryPayload, createdAt: r.enqueuedAt)
        appended.append(entryRow.toModel())

        try db.execute(
          sql: "DELETE FROM user_queue_pending WHERE sessionID = ? AND lane = ? AND id = ?",
          arguments: [sessionID.rawValue, UserQueueLane.followUp.rawValue, r.id],
        )

        let transcriptEntryID = TranscriptEntryID(rawValue: "\(entryRow.id ?? -1)")
        let journal = UserQueueJournalEntry.materialized(
          lane: .followUp,
          id: QueueItemID(rawValue: r.id),
          transcriptEntryID: transcriptEntryID,
          at: Date(),
        )
        let data = try WuhuJSON.encoder.encode(journal)
        try db.execute(
          sql: "INSERT INTO user_queue_journal (sessionID, lane, payload, createdAt) VALUES (?, ?, ?, ?)",
          arguments: [sessionID.rawValue, UserQueueLane.followUp.rawValue, data, Date()],
        )
      }

      let session = try sessionRow.toModel()
      return try DrainResult(
        didDrain: true,
        session: session,
        entries: appended,
        systemUrgent: Self.loadSystemQueueBackfill(db: db, sessionID: sessionID),
        steer: Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .steer),
        followUp: Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .followUp),
      )
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

  func loadToolCallStatus(sessionID: SessionID) async throws -> [String: ToolCallRecord] {
    try await dbQueue.read { db in
      let rows = try ToolCallStatusRow
        .filter(Column("sessionID") == sessionID.rawValue)
        .fetchAll(db)
      var out: [String: ToolCallRecord] = [:]
      out.reserveCapacity(rows.count)
      for r in rows {
        let status = ToolCallStatus(rawValue: r.status) ?? .pending
        out[r.toolCallID] = ToolCallRecord(status: status, updatedAt: r.updatedAt)
      }
      return out
    }
  }

  /// Look up which session a tool call belongs to.
  /// Returns nil if the tool call ID is not found.
  func lookupSessionForToolCall(toolCallID: String) async throws -> String? {
    try await dbQueue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT sessionID FROM tool_call_status WHERE toolCallID = ?",
        arguments: [toolCallID],
      )
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
    let now = Date()
    try await dbQueue.write { db in
      try db.execute(
        sql: """
        INSERT INTO tool_call_status (sessionID, toolCallID, status, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(sessionID, toolCallID) DO UPDATE SET status = excluded.status, updatedAt = excluded.updatedAt
        """,
        arguments: [sessionID.rawValue, id, status.rawValue, now, now],
      )
      if status == .pending || status == .started {
        try Self.setExecutionStatus(db: db, sessionID: sessionID.rawValue, status: .running)
      }
    }
    return .init(id: id, status: status)
  }

  func appendEntryWithSession(sessionID: SessionID, payload: WuhuEntryPayload, createdAt: Date) async throws -> (WuhuSession, WuhuSessionEntry) {
    try await dbQueue.write { db in
      guard var sessionRow = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw StoreError.sessionNotFound(sessionID.rawValue)
      }
      let entryRow = try Self.appendEntryWithSession(db: db, sessionRow: &sessionRow, payload: payload, createdAt: createdAt)
      return try (sessionRow.toModel(), entryRow.toModel())
    }
  }

  // MARK: - Rename

  public func renameSession(id: String, title: String) async throws -> WuhuSession {
    try await dbQueue.write { db in
      guard var row = try SessionRow.fetchOne(db, key: id) else {
        throw StoreError.sessionNotFound(id)
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
        throw StoreError.sessionNotFound(id)
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
        throw StoreError.sessionNotFound(id)
      }
      row.isArchived = false
      row.updatedAt = Date()
      try row.update(db)
      return try row.toModel()
    }
  }
}
