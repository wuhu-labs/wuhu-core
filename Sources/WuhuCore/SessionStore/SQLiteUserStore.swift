import Foundation
import GRDB
import WuhuAPI

/// Persists users in the shared ``WuhuDatabase``.
public actor SQLiteUserStore {
  private let dbQueue: DatabaseQueue

  public init(database: WuhuDatabase) {
    dbQueue = database.dbQueue
  }

  // MARK: - Row type

  struct UserRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "users"

    var id: String
    var username: String
    var kind: String
    var createdAt: Date
    var updatedAt: Date

    func toModel() -> WuhuUser {
      .init(
        id: id,
        username: username,
        kind: WuhuUserKind(rawValue: kind) ?? .human,
        createdAt: createdAt,
        updatedAt: updatedAt,
      )
    }
  }

  // MARK: - Public API

  public func createUser(username: String, kind: WuhuUserKind = .human) async throws -> WuhuUser {
    let now = Date()
    let id = UUID().uuidString.lowercased()
    let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw WuhuUserStoreError.invalidUsername("Username cannot be empty")
    }

    return try await dbQueue.write { db in
      var row = UserRow(
        id: id,
        username: trimmed,
        kind: kind.rawValue,
        createdAt: now,
        updatedAt: now,
      )
      try row.insert(db)
      return row.toModel()
    }
  }

  /// Upsert a user by username. If the username exists, updates kind if it changed.
  /// Returns the user and whether it was newly created.
  public func upsertUser(username: String, kind: WuhuUserKind = .human) async throws -> (user: WuhuUser, created: Bool) {
    let now = Date()
    let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw WuhuUserStoreError.invalidUsername("Username cannot be empty")
    }

    return try await dbQueue.write { db in
      if var existing = try UserRow.filter(Column("username") == trimmed).fetchOne(db) {
        if existing.kind != kind.rawValue {
          existing.kind = kind.rawValue
          existing.updatedAt = now
          try existing.update(db)
        }
        return (user: existing.toModel(), created: false)
      }

      let id = UUID().uuidString.lowercased()
      var row = UserRow(
        id: id,
        username: trimmed,
        kind: kind.rawValue,
        createdAt: now,
        updatedAt: now,
      )
      try row.insert(db)
      return (user: row.toModel(), created: true)
    }
  }

  public func getUser(id: String) async throws -> WuhuUser {
    try await dbQueue.read { db in
      guard let row = try UserRow.fetchOne(db, key: id) else {
        throw WuhuUserStoreError.userNotFound(id)
      }
      return row.toModel()
    }
  }

  public func getUserByUsername(_ username: String) async throws -> WuhuUser? {
    let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
    return try await dbQueue.read { db in
      try UserRow.filter(Column("username") == trimmed).fetchOne(db)?.toModel()
    }
  }

  public func listUsers() async throws -> [WuhuUser] {
    try await dbQueue.read { db in
      try UserRow.order(Column("username").asc).fetchAll(db).map { $0.toModel() }
    }
  }

  public func deleteUser(id: String) async throws {
    try await dbQueue.write { db in
      guard let row = try UserRow.fetchOne(db, key: id) else {
        throw WuhuUserStoreError.userNotFound(id)
      }
      _ = try row.delete(db)
    }
  }
}

public enum WuhuUserStoreError: Error, Sendable, CustomStringConvertible {
  case userNotFound(String)
  case invalidUsername(String)
  case usernameAlreadyExists(String)

  public var description: String {
    switch self {
    case let .userNotFound(id):
      "User not found: \(id)"
    case let .invalidUsername(reason):
      "Invalid username: \(reason)"
    case let .usernameAlreadyExists(name):
      "Username already exists: \(name)"
    }
  }
}
