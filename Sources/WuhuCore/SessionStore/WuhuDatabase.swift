import Foundation
import GRDB

/// Shared database layer that owns the GRDB `DatabaseQueue`.
///
/// Both `SQLiteSessionStore` and `SQLiteChannelStore` use the same
/// underlying database via this type. Migrations run once at init.
public final class WuhuDatabase: Sendable {
  public let dbQueue: DatabaseQueue

  public init(path: String) throws {
    var config = Configuration()
    config.foreignKeysEnabled = true
    config.busyMode = .timeout(5)

    dbQueue = try DatabaseQueue(path: path, configuration: config)
    try Self.migrator.migrate(dbQueue)
  }

  static let migrator: DatabaseMigrator = {
    var migrator = DatabaseMigrator()
    Migration_V1.register(in: &migrator)
    Migration_V2.register(in: &migrator)
    Migration_V3.register(in: &migrator)
    Migration_V4.register(in: &migrator)
    Migration_V5.register(in: &migrator)
    Migration_V6.register(in: &migrator)
    Migration_V7.register(in: &migrator)
    Migration_V8.register(in: &migrator)
    Migration_V9.register(in: &migrator)
    return migrator
  }()
}
