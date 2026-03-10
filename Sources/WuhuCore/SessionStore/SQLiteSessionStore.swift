import Foundation
import GRDB
import PiAI
import WuhuAPI

public actor SQLiteSessionStore: SessionStore {
  let dbQueue: DatabaseQueue

  public init(path: String) throws {
    var config = Configuration()
    config.foreignKeysEnabled = true
    config.busyMode = .timeout(5)

    dbQueue = try DatabaseQueue(path: path, configuration: config)
    try Self.migrator.migrate(dbQueue)
  }

  // MARK: - Mount Templates

  public func createMountTemplate(_ request: WuhuCreateMountTemplateRequest) async throws -> WuhuMountTemplate {
    let now = Date()
    let id = UUID().uuidString.lowercased()

    let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let templatePath = request.templatePath.trimmingCharacters(in: .whitespacesAndNewlines)
    let workspacesPath = request.workspacesPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let startupScript = request.startupScript?.trimmingCharacters(in: .whitespacesAndNewlines)

    return try await dbQueue.write { db in
      var row = MountTemplateRow(
        id: id,
        name: name,
        type: request.type.rawValue,
        templatePath: templatePath,
        workspacesPath: workspacesPath,
        startupScript: startupScript?.isEmpty == false ? startupScript : nil,
        createdAt: now,
        updatedAt: now,
      )
      try row.insert(db)
      return try row.toModel()
    }
  }

  public func listMountTemplates() async throws -> [WuhuMountTemplate] {
    try await dbQueue.read { db in
      try MountTemplateRow
        .order(Column("name").asc)
        .fetchAll(db)
        .map { try $0.toModel() }
    }
  }

  public func getMountTemplate(identifier raw: String) async throws -> WuhuMountTemplate {
    let identifier = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty else { throw MountTemplateResolutionError.unknownMountTemplate(raw) }

    return try await dbQueue.read { db in
      let row: MountTemplateRow? = if UUID(uuidString: identifier) != nil {
        try MountTemplateRow.fetchOne(db, key: identifier.lowercased())
      } else {
        try MountTemplateRow.filter(Column("name") == identifier).fetchOne(db)
      }

      guard let row else {
        throw MountTemplateResolutionError.unknownMountTemplate(identifier)
      }
      return try row.toModel()
    }
  }

  public func updateMountTemplate(
    identifier raw: String,
    request: WuhuUpdateMountTemplateRequest,
  ) async throws -> WuhuMountTemplate {
    let identifier = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty else { throw MountTemplateResolutionError.unknownMountTemplate(raw) }

    let now = Date()
    return try await dbQueue.write { db in
      let row: MountTemplateRow? = if UUID(uuidString: identifier) != nil {
        try MountTemplateRow.fetchOne(db, key: identifier.lowercased())
      } else {
        try MountTemplateRow.filter(Column("name") == identifier).fetchOne(db)
      }

      guard var row else {
        throw MountTemplateResolutionError.unknownMountTemplate(identifier)
      }

      if let name = request.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
        row.name = name
      }
      if let templatePath = request.templatePath?.trimmingCharacters(in: .whitespacesAndNewlines), !templatePath.isEmpty {
        row.templatePath = templatePath
      }
      if let workspacesPath = request.workspacesPath?.trimmingCharacters(in: .whitespacesAndNewlines), !workspacesPath.isEmpty {
        row.workspacesPath = workspacesPath
      }
      if let startupScript = request.startupScript {
        let trimmed = startupScript?.trimmingCharacters(in: .whitespacesAndNewlines)
        row.startupScript = (trimmed?.isEmpty == false) ? trimmed : nil
      }

      row.updatedAt = now
      try row.update(db)
      return try row.toModel()
    }
  }

  public func deleteMountTemplate(identifier raw: String) async throws {
    let identifier = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty else { throw MountTemplateResolutionError.unknownMountTemplate(raw) }

    try await dbQueue.write { db in
      let row: MountTemplateRow? = if UUID(uuidString: identifier) != nil {
        try MountTemplateRow.fetchOne(db, key: identifier.lowercased())
      } else {
        try MountTemplateRow.filter(Column("name") == identifier).fetchOne(db)
      }

      guard let row else {
        throw MountTemplateResolutionError.unknownMountTemplate(identifier)
      }
      _ = try row.delete(db)
    }
  }

  // MARK: - Mounts

  public func createMount(
    sessionID: String,
    name: String,
    path: String,
    mountTemplateID: String? = nil,
    isPrimary: Bool = true,
    runnerID: RunnerID = .local,
  ) async throws -> WuhuMount {
    let now = Date()
    let id = UUID().uuidString.lowercased()

    return try await dbQueue.write { db in
      var row = MountRow(
        id: id,
        sessionID: sessionID,
        name: name,
        path: path,
        mountTemplateID: mountTemplateID,
        isPrimary: isPrimary,
        runnerID: runnerID.wireValue,
        createdAt: now,
      )
      try row.insert(db)
      return row.toModel()
    }
  }

  public func listMounts(sessionID: String) async throws -> [WuhuMount] {
    try await dbQueue.read { db in
      try MountRow
        .filter(Column("sessionID") == sessionID)
        .order(Column("createdAt").asc)
        .fetchAll(db)
        .map { $0.toModel() }
    }
  }

  public func getPrimaryMount(sessionID: String) async throws -> WuhuMount? {
    try await dbQueue.read { db in
      try MountRow
        .filter(Column("sessionID") == sessionID && Column("isPrimary") == true)
        .fetchOne(db)
        .map { $0.toModel() }
    }
  }

  public func getMountByName(sessionID: String, name: String) async throws -> WuhuMount? {
    try await dbQueue.read { db in
      try MountRow
        .filter(Column("sessionID") == sessionID && Column("name") == name)
        .fetchOne(db)
        .map { $0.toModel() }
    }
  }

  // MARK: - Sessions

  public func createSession(
    sessionID rawSessionID: String,
    provider: WuhuProvider,
    model: String,
    reasoningEffort: ReasoningEffort?,
    systemPrompt: String,
    cwd: String?,
    parentSessionID: String?,
  ) async throws -> WuhuSession {
    let now = Date()
    let sessionID = rawSessionID.lowercased()

    return try await dbQueue.write { db in
      var sessionRow = SessionRow(
        id: sessionID,
        provider: provider.rawValue,
        model: model,
        effectiveReasoningEffort: reasoningEffort?.rawValue,
        pendingProvider: nil,
        pendingModel: nil,
        pendingReasoningEffort: nil,
        executionStatus: SessionExecutionStatus.idle.rawValue,
        cwd: cwd,
        parentSessionID: parentSessionID,
        isArchived: false,
        createdAt: now,
        updatedAt: now,
        headEntryID: nil,
        tailEntryID: nil,
      )
      try sessionRow.insert(db)

      var headerMetadata: [String: JSONValue] = [:]
      if let reasoningEffort {
        headerMetadata["reasoningEffort"] = .string(reasoningEffort.rawValue)
      }
      let headerPayload = WuhuEntryPayload.header(.init(
        systemPrompt: systemPrompt,
        metadata: .object(headerMetadata),
      ))
      var headerRow = try EntryRow.new(
        sessionID: sessionID,
        parentEntryID: nil,
        payload: headerPayload,
        createdAt: now,
      )
      try headerRow.insert(db)
      guard let headerID = headerRow.id else {
        throw StoreError.sessionCorrupt("Failed to create header entry id")
      }

      sessionRow.headEntryID = headerID
      sessionRow.tailEntryID = headerID
      try sessionRow.update(db)

      return try sessionRow.toModel()
    }
  }

  public func getSession(id: String) async throws -> WuhuSession {
    try await dbQueue.read { db in
      guard let row = try SessionRow.fetchOne(db, key: id) else {
        throw StoreError.sessionNotFound(id)
      }
      return try row.toModel()
    }
  }

  public func listSessions(limit: Int? = nil, includeArchived: Bool = false) async throws -> [WuhuSession] {
    try await dbQueue.read { db in
      var req = SessionRow.order(Column("updatedAt").desc)
      if !includeArchived {
        req = req.filter(Column("isArchived") == false)
      }
      if let limit { req = req.limit(limit) }
      return try req.fetchAll(db).map { try $0.toModel() }
    }
  }

  // MARK: - Channels / Child Sessions

  struct ChildSessionRecord: Sendable, Hashable {
    var session: WuhuSession
    var executionStatus: SessionExecutionStatus
  }

  func listChildSessions(parentSessionID: String) async throws -> [ChildSessionRecord] {
    try await dbQueue.read { db in
      let sessionRows = try SessionRow
        .filter(Column("parentSessionID") == parentSessionID)
        .order(Column("updatedAt").desc)
        .fetchAll(db)

      return try sessionRows.map { row in
        let exec = SessionExecutionStatus(rawValue: row.executionStatus) ?? .idle
        let session = try row.toModel()
        return .init(
          session: session,
          executionStatus: exec,
        )
      }
    }
  }

  @discardableResult
  public func appendEntry(sessionID: String, payload: WuhuEntryPayload) async throws -> WuhuSessionEntry {
    let (_, entry) = try await appendEntryWithSession(
      sessionID: SessionID(rawValue: sessionID),
      payload: payload,
      createdAt: Date(),
    )
    return entry
  }

  public func getEntries(sessionID: String) async throws -> [WuhuSessionEntry] {
    try await dbQueue.read { db in
      guard let sessionRow = try SessionRow.fetchOne(db, key: sessionID) else {
        throw StoreError.sessionNotFound(sessionID)
      }
      let session = try sessionRow.toModel()
      let rows = try EntryRow
        .filter(Column("sessionID") == sessionID)
        .fetchAll(db)
      let entries = rows.map { $0.toModel() }
      return try Self.linearize(
        entries: entries,
        sessionID: sessionID,
        headEntryID: session.headEntryID,
        tailEntryID: session.tailEntryID,
      )
    }
  }

  func getEntriesReverse(
    sessionID: String,
    beforeEntryID: Int64?,
    limit: Int,
  ) async throws -> [WuhuSessionEntry] {
    try await dbQueue.read { db in
      guard let _ = try SessionRow.fetchOne(db, key: sessionID) else {
        throw StoreError.sessionNotFound(sessionID)
      }

      var filter = Column("sessionID") == sessionID
      if let beforeEntryID {
        filter = filter && Column("id") < beforeEntryID
      }

      var req = EntryRow.filter(filter)
      req = req.order(Column("id").desc).limit(limit)
      return try req.fetchAll(db).map { $0.toModel() }
    }
  }

  public func getEntries(
    sessionID: String,
    sinceCursor: Int64?,
    sinceTime: Date?,
  ) async throws -> [WuhuSessionEntry] {
    try await dbQueue.read { db in
      guard let _ = try SessionRow.fetchOne(db, key: sessionID) else {
        throw StoreError.sessionNotFound(sessionID)
      }

      var filter = Column("sessionID") == sessionID
      if let sinceCursor {
        filter = filter && Column("id") > sinceCursor
      }
      if let sinceTime {
        filter = filter && Column("createdAt") > sinceTime
      }

      var req = EntryRow.filter(filter)
      req = req.order(Column("id").asc)
      return try req.fetchAll(db).map { $0.toModel() }
    }
  }

  /// Update the session's cwd.
  func setSessionCwd(sessionID: String, cwd: String?) async throws {
    try await dbQueue.write { db in
      try db.execute(
        sql: "UPDATE sessions SET cwd = ?, updatedAt = ? WHERE id = ?",
        arguments: [cwd, Date(), sessionID],
      )
    }
  }

  private static func linearize(
    entries: [WuhuSessionEntry],
    sessionID: String,
    headEntryID: Int64,
    tailEntryID: Int64,
  ) throws -> [WuhuSessionEntry] {
    var byID: [Int64: WuhuSessionEntry] = [:]
    byID.reserveCapacity(entries.count)

    var childByParent: [Int64: WuhuSessionEntry] = [:]
    childByParent.reserveCapacity(entries.count)

    var header: WuhuSessionEntry?
    for entry in entries {
      byID[entry.id] = entry
      if let parent = entry.parentEntryID {
        childByParent[parent] = entry
      } else {
        header = entry
      }
    }

    guard let header else { throw StoreError.noHeaderEntry(sessionID) }
    guard header.id == headEntryID else {
      throw StoreError.sessionCorrupt("headEntryID=\(headEntryID) does not match header.id=\(header.id)")
    }

    var ordered: [WuhuSessionEntry] = []
    ordered.reserveCapacity(entries.count)

    var current = header
    ordered.append(current)
    var seen = Set<Int64>()
    seen.insert(current.id)

    while let child = childByParent[current.id] {
      if seen.contains(child.id) {
        throw StoreError.sessionCorrupt("Cycle detected at entry \(child.id)")
      }
      ordered.append(child)
      seen.insert(child.id)
      current = child
    }

    guard current.id == tailEntryID else {
      throw StoreError.sessionCorrupt("tailEntryID=\(tailEntryID) does not match last.id=\(current.id)")
    }

    if ordered.count != entries.count {
      throw StoreError.sessionCorrupt("Entries are not a single linear chain (expected \(entries.count), got \(ordered.count))")
    }

    return ordered
  }
}
