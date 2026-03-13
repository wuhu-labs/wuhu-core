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
