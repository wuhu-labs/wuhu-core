import GRDB

extension SQLiteSessionStore {
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
    return migrator
  }()
}
