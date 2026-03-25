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

  struct SessionMetadataUpdate: Sendable {
    var customTitle: String?
    var isArchived: Bool
    var cwd: String?
  }

  struct LoopPersistencePatch: Sendable {
    var pendingModelSelection: WuhuSessionSettings?
    var systemJournalEntries: [SystemUrgentQueueJournalEntry]
    var steerJournalEntries: [UserQueueJournalEntry]
    var followUpJournalEntries: [UserQueueJournalEntry]
    var standaloneEntries: [WuhuSessionEntry]
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

  func setPendingModelSelection(sessionID: SessionID, selection: WuhuSessionSettings) async throws -> SessionSettingsSnapshot {
    try await dbQueue.write { db in
      guard var sessionRow = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw WuhuStoreError.sessionNotFound(sessionID.rawValue)
      }
      try Self.setPendingModelSelection(db: db, sessionRow: &sessionRow, selection: selection)
    }
    return try await loadSettingsSnapshot(sessionID: sessionID)
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

      try Self.persistInterruptJournalEntries(
        db: db,
        sessionID: sessionID,
        sessionRow: &sessionRow,
        systemEntries: patch.systemJournalEntries,
        steerEntries: patch.steerJournalEntries,
      )
      try Self.persistFollowUpJournalEntries(
        db: db,
        sessionID: sessionID,
        sessionRow: &sessionRow,
        entries: patch.followUpJournalEntries,
      )
      try Self.persistStandaloneEntries(
        db: db,
        sessionID: sessionID,
        sessionRow: &sessionRow,
        entries: patch.standaloneEntries,
      )

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

  func applyModelSelection(
    sessionID: SessionID,
    selection: WuhuSessionSettings,
    entryID: Int64? = nil,
  ) async throws -> (session: WuhuSession, entry: WuhuSessionEntry, settings: SessionSettingsSnapshot) {
    let (session, entry) = try await appendEntryWithSession(
      sessionID: sessionID,
      payload: .sessionSettings(selection),
      createdAt: Date(),
      entryID: entryID,
    )
    let settings = try await loadSettingsSnapshot(sessionID: sessionID)
    return (session, entry, settings)
  }

  func applyPendingModelIfPossible(
    sessionID: SessionID,
    entryID: Int64? = nil,
  ) async throws -> (session: WuhuSession, entry: WuhuSessionEntry, settings: SessionSettingsSnapshot)? {
    let result: (WuhuSession, WuhuSessionEntry)? = try await dbQueue.write { db in
      guard var row = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw WuhuStoreError.sessionNotFound(sessionID.rawValue)
      }
      guard let p = row.pendingProvider, let m = row.pendingModel else { return nil }

      // Only apply when no other work is pending.
      guard row.executionStatus == SessionExecutionStatus.idle.rawValue else { return nil }
      guard try Self.pendingWorkCount(db: db, sessionID: sessionID.rawValue) == 0 else { return nil }

      let provider = WuhuProvider(rawValue: p) ?? .openai
      let selection = WuhuSessionSettings(provider: provider, model: m, reasoningEffort: row.pendingReasoningEffort.flatMap(ReasoningEffort.init(rawValue:)))

      let entryRow = try Self.appendEntryWithSession(
        db: db,
        sessionRow: &row,
        payload: .sessionSettings(selection),
        createdAt: Date(),
        entryID: entryID,
      )
      return try (row.toModel(), entryRow.toModel())
    }

    guard let result else { return nil }
    return try await (result.0, result.1, loadSettingsSnapshot(sessionID: sessionID))
  }

  func enqueueUserMessage(
    sessionID: SessionID,
    id: QueueItemID,
    message: QueuedUserMessage,
    lane: UserQueueLane,
    enqueuedAt: Date? = nil,
  ) async throws -> QueueItemID {
    let now = enqueuedAt ?? Date()
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
        throw WuhuStoreError.sessionCorrupt("Queue item not found: \(id.rawValue)")
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

  func drainInterruptCheckpoint(sessionID: SessionID, reservedEntryIDs: [Int64]? = nil) async throws -> DrainResult {
    let _ = reservedEntryIDs
    return try await dbQueue.write { db in
      guard var sessionRow = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw WuhuStoreError.sessionNotFound(sessionID.rawValue)
      }
      let appended = try Self.drainInterruptCheckpoint(
        db: db,
        sessionID: sessionID,
        sessionRow: &sessionRow,
      )

      let session = try sessionRow.toModel()
      return try DrainResult(
        didDrain: !appended.isEmpty,
        session: session,
        entries: appended,
        systemUrgent: Self.loadSystemQueueBackfill(db: db, sessionID: sessionID),
        steer: Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .steer),
        followUp: Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .followUp),
      )
    }
  }

  func drainTurnBoundary(sessionID: SessionID, reservedEntryIDs: [Int64]? = nil) async throws -> DrainResult {
    let _ = reservedEntryIDs
    return try await dbQueue.write { db in
      guard var sessionRow = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw WuhuStoreError.sessionNotFound(sessionID.rawValue)
      }
      let appended = try Self.drainTurnBoundary(
        db: db,
        sessionID: sessionID,
        sessionRow: &sessionRow,
      )

      let session = try sessionRow.toModel()
      return try DrainResult(
        didDrain: !appended.isEmpty,
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

  private static func persistInterruptJournalEntries(
    db: Database,
    sessionID: SessionID,
    sessionRow: inout SessionRow,
    systemEntries: [SystemUrgentQueueJournalEntry],
    steerEntries: [UserQueueJournalEntry],
  ) throws {
    enum ReplayEntry {
      case system(SystemUrgentQueueJournalEntry)
      case steer(UserQueueJournalEntry)

      var timestamp: Date {
        switch self {
        case let .system(.enqueued(item)):
          item.enqueuedAt
        case let .system(.materialized(_, _, at)):
          at
        case let .steer(.enqueued(_, item)):
          item.enqueuedAt
        case let .steer(.canceled(_, _, at)):
          at
        case let .steer(.materialized(_, _, _, at)):
          at
        }
      }

      var stableID: String {
        switch self {
        case let .system(.enqueued(item)):
          item.id.rawValue
        case let .system(.materialized(id, _, _)):
          id.rawValue
        case let .steer(.enqueued(_, item)):
          item.id.rawValue
        case let .steer(.canceled(_, id, _)):
          id.rawValue
        case let .steer(.materialized(_, id, _, _)):
          id.rawValue
        }
      }

      var laneOrder: Int {
        switch self {
        case .system:
          0
        case .steer:
          1
        }
      }

      var isMaterialized: Bool {
        switch self {
        case let .system(entry):
          if case .materialized = entry { return true }
          return false
        case let .steer(entry):
          if case .materialized = entry { return true }
          return false
        }
      }
    }

    var entries = systemEntries.map(ReplayEntry.system)
    entries += steerEntries.map(ReplayEntry.steer)
    entries.sort { lhs, rhs in
      if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
      if lhs.isMaterialized != rhs.isMaterialized { return !lhs.isMaterialized }
      if lhs.stableID != rhs.stableID { return lhs.stableID < rhs.stableID }
      return lhs.laneOrder < rhs.laneOrder
    }

    var index = 0
    while index < entries.count {
      let entry = entries[index]

      if entry.isMaterialized {
        _ = try drainInterruptCheckpoint(db: db, sessionID: sessionID, sessionRow: &sessionRow)
        repeat {
          index += 1
        } while index < entries.count && entries[index].isMaterialized
        continue
      }

      switch entry {
      case let .system(systemEntry):
        try persistSystemQueueJournalEntry(db: db, sessionID: sessionID, systemEntry)
      case let .steer(steerEntry):
        try persistUserQueueJournalEntry(db: db, sessionID: sessionID, steerEntry, lane: .steer)
      }

      index += 1
    }
  }

  private static func persistFollowUpJournalEntries(
    db: Database,
    sessionID: SessionID,
    sessionRow: inout SessionRow,
    entries: [UserQueueJournalEntry],
  ) throws {
    var remaining = entries[...]

    while !remaining.isEmpty {
      let materializedIndex = remaining.firstIndex(where: isMaterialized(_:))
      let prefixEnd = materializedIndex ?? remaining.endIndex

      for entry in remaining[..<prefixEnd] {
        try persistUserQueueJournalEntry(db: db, sessionID: sessionID, entry, lane: .followUp)
      }

      remaining.removeFirst(remaining.distance(from: remaining.startIndex, to: prefixEnd))

      guard remaining.first.map(isMaterialized(_:)) == true else { break }
      _ = try drainTurnBoundary(db: db, sessionID: sessionID, sessionRow: &sessionRow)

      while remaining.first.map(isMaterialized(_:)) == true {
        remaining.removeFirst()
      }
    }
  }

  private static func persistStandaloneEntries(
    db: Database,
    sessionID _: SessionID,
    sessionRow: inout SessionRow,
    entries: [WuhuSessionEntry],
  ) throws {
    for entry in entries {
      _ = try appendEntryWithSession(
        db: db,
        sessionRow: &sessionRow,
        payload: entry.payload,
        createdAt: entry.createdAt,
        entryID: nil,
      )
    }
  }

  private static func persistSystemQueueJournalEntry(
    db: Database,
    sessionID: SessionID,
    _ entry: SystemUrgentQueueJournalEntry,
  ) throws {
    switch entry {
    case let .enqueued(item):
      let data = try WuhuJSON.encoder.encode(item.input)
      try db.execute(
        sql: "INSERT INTO system_queue_pending (id, sessionID, enqueuedAt, payload) VALUES (?, ?, ?, ?)",
        arguments: [item.id.rawValue, sessionID.rawValue, item.enqueuedAt, data],
      )

      let journalData = try WuhuJSON.encoder.encode(entry)
      try db.execute(
        sql: "INSERT INTO system_queue_journal (sessionID, payload, createdAt) VALUES (?, ?, ?)",
        arguments: [sessionID.rawValue, journalData, item.enqueuedAt],
      )

      try updateSessionUpdatedAt(db: db, sessionID: sessionID.rawValue)
      try setExecutionStatus(db: db, sessionID: sessionID.rawValue, status: .running)

    case .materialized:
      throw WuhuStoreError.sessionCorrupt("Unexpected materialized system queue diff")
    }
  }

  private static func persistUserQueueJournalEntry(
    db: Database,
    sessionID: SessionID,
    _ entry: UserQueueJournalEntry,
    lane: UserQueueLane,
  ) throws {
    switch entry {
    case let .enqueued(_, item):
      let data = try WuhuJSON.encoder.encode(item.message)
      try db.execute(
        sql: """
        INSERT INTO user_queue_pending (id, sessionID, lane, enqueuedAt, payload)
        VALUES (?, ?, ?, ?, ?)
        """,
        arguments: [item.id.rawValue, sessionID.rawValue, lane.rawValue, item.enqueuedAt, data],
      )

      let journalData = try WuhuJSON.encoder.encode(entry)
      try db.execute(
        sql: """
        INSERT INTO user_queue_journal (sessionID, lane, payload, createdAt)
        VALUES (?, ?, ?, ?)
        """,
        arguments: [sessionID.rawValue, lane.rawValue, journalData, item.enqueuedAt],
      )

      try updateSessionUpdatedAt(db: db, sessionID: sessionID.rawValue)
      try setExecutionStatus(db: db, sessionID: sessionID.rawValue, status: .running)

    case let .canceled(_, id, at):
      try db.execute(
        sql: "DELETE FROM user_queue_pending WHERE sessionID = ? AND lane = ? AND id = ?",
        arguments: [sessionID.rawValue, lane.rawValue, id.rawValue],
      )
      if db.changesCount == 0 {
        throw WuhuStoreError.sessionCorrupt("Queue item not found: \(id.rawValue)")
      }

      let journalData = try WuhuJSON.encoder.encode(entry)
      try db.execute(
        sql: "INSERT INTO user_queue_journal (sessionID, lane, payload, createdAt) VALUES (?, ?, ?, ?)",
        arguments: [sessionID.rawValue, lane.rawValue, journalData, at],
      )

      try updateSessionUpdatedAt(db: db, sessionID: sessionID.rawValue)
      try maybeSetIdleIfNoPendingWork(db: db, sessionID: sessionID.rawValue)

    case .materialized:
      throw WuhuStoreError.sessionCorrupt("Unexpected materialized queue journal diff")
    }
  }

  private static func drainInterruptCheckpoint(
    db: Database,
    sessionID: SessionID,
    sessionRow: inout SessionRow,
  ) throws -> [WuhuSessionEntry] {
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
    for row in systemRows {
      candidates.append(.init(enqueuedAt: row.enqueuedAt, kind: "system", id: row.id, payload: row.payload))
    }
    for row in steerRows {
      candidates.append(.init(enqueuedAt: row.enqueuedAt, kind: "steer", id: row.id, payload: row.payload))
    }
    candidates.sort { lhs, rhs in
      if lhs.enqueuedAt != rhs.enqueuedAt { return lhs.enqueuedAt < rhs.enqueuedAt }
      return lhs.id < rhs.id
    }

    var appended: [WuhuSessionEntry] = []
    appended.reserveCapacity(candidates.count)

    for candidate in candidates {
      let entryPayload: WuhuEntryPayload
      let createdAt = candidate.enqueuedAt

      if candidate.kind == "system" {
        let input = try WuhuJSON.decoder.decode(SystemUrgentInput.self, from: candidate.payload)
        let custom = WuhuCustomMessage(
          customType: "wuhu_system_input_v1",
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
          arguments: [sessionID.rawValue, candidate.id],
        )
      } else {
        let message = try WuhuJSON.decoder.decode(QueuedUserMessage.self, from: candidate.payload)
        let user = WuhuUserMessage(
          user: userString(message.author),
          content: message.content.toContentBlocks(),
          timestamp: createdAt,
        )
        entryPayload = .message(.user(user))
        try db.execute(
          sql: "DELETE FROM user_queue_pending WHERE sessionID = ? AND lane = ? AND id = ?",
          arguments: [sessionID.rawValue, UserQueueLane.steer.rawValue, candidate.id],
        )
      }

      let entryRow = try appendEntryWithSession(
        db: db,
        sessionRow: &sessionRow,
        payload: entryPayload,
        createdAt: createdAt,
      )
      appended.append(entryRow.toModel())
      let transcriptEntryID = TranscriptEntryID(rawValue: "\(entryRow.id ?? -1)")
      let journalAt = Date()

      if candidate.kind == "system" {
        let journal = SystemUrgentQueueJournalEntry.materialized(
          id: QueueItemID(rawValue: candidate.id),
          transcriptEntryID: transcriptEntryID,
          at: journalAt,
        )
        let data = try WuhuJSON.encoder.encode(journal)
        try db.execute(
          sql: "INSERT INTO system_queue_journal (sessionID, payload, createdAt) VALUES (?, ?, ?)",
          arguments: [sessionID.rawValue, data, journalAt],
        )
      } else {
        let journal = UserQueueJournalEntry.materialized(
          lane: .steer,
          id: QueueItemID(rawValue: candidate.id),
          transcriptEntryID: transcriptEntryID,
          at: journalAt,
        )
        let data = try WuhuJSON.encoder.encode(journal)
        try db.execute(
          sql: "INSERT INTO user_queue_journal (sessionID, lane, payload, createdAt) VALUES (?, ?, ?, ?)",
          arguments: [sessionID.rawValue, UserQueueLane.steer.rawValue, data, journalAt],
        )
      }
    }

    return appended
  }

  private static func drainTurnBoundary(
    db: Database,
    sessionID: SessionID,
    sessionRow: inout SessionRow,
  ) throws -> [WuhuSessionEntry] {
    let followRows = try UserQueuePendingRow
      .filter(Column("sessionID") == sessionID.rawValue && Column("lane") == UserQueueLane.followUp.rawValue)
      .order(Column("enqueuedAt").asc)
      .fetchAll(db)

    var appended: [WuhuSessionEntry] = []
    appended.reserveCapacity(followRows.count)

    for row in followRows {
      let message = try WuhuJSON.decoder.decode(QueuedUserMessage.self, from: row.payload)
      let user = WuhuUserMessage(
        user: userString(message.author),
        content: message.content.toContentBlocks(),
        timestamp: row.enqueuedAt,
      )

      let entryRow = try appendEntryWithSession(
        db: db,
        sessionRow: &sessionRow,
        payload: .message(.user(user)),
        createdAt: row.enqueuedAt,
      )
      appended.append(entryRow.toModel())

      try db.execute(
        sql: "DELETE FROM user_queue_pending WHERE sessionID = ? AND lane = ? AND id = ?",
        arguments: [sessionID.rawValue, UserQueueLane.followUp.rawValue, row.id],
      )

      let transcriptEntryID = TranscriptEntryID(rawValue: "\(entryRow.id ?? -1)")
      let journal = UserQueueJournalEntry.materialized(
        lane: .followUp,
        id: QueueItemID(rawValue: row.id),
        transcriptEntryID: transcriptEntryID,
        at: Date(),
      )
      let data = try WuhuJSON.encoder.encode(journal)
      try db.execute(
        sql: "INSERT INTO user_queue_journal (sessionID, lane, payload, createdAt) VALUES (?, ?, ?, ?)",
        arguments: [sessionID.rawValue, UserQueueLane.followUp.rawValue, data, Date()],
      )
    }

    return appended
  }

  private static func isMaterialized(_ entry: UserQueueJournalEntry) -> Bool {
    if case .materialized = entry { return true }
    return false
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
