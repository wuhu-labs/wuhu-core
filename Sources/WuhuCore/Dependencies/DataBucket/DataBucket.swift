import Dependencies
import Foundation

// MARK: - DataBucket protocol

/// A simple key→Data store. The fundamental storage primitive.
///
/// Keys are opaque strings — callers decide the namespace/structure.
/// Implementations handle where and how bytes are persisted.
public protocol DataBucket: Sendable {
  /// Write data at the given key. Creates intermediate structure as needed.
  func write(key: String, data: Data) async throws

  /// Read data for the given key. Returns nil if the key doesn't exist.
  func read(key: String) async throws -> Data?

  /// Check whether a key exists.
  func exists(key: String) async throws -> Bool
}

// MARK: - Dependency registration

private enum DataBucketKey: DependencyKey {
  static let liveValue: any DataBucket = LocalDataBucket(rootDirectory: NSTemporaryDirectory() + "wuhu-data")
  static let testValue: any DataBucket = LocalDataBucket(rootDirectory: NSTemporaryDirectory() + "wuhu-data-test")
}

public extension DependencyValues {
  var dataBucket: any DataBucket {
    get { self[DataBucketKey.self] }
    set { self[DataBucketKey.self] = newValue }
  }
}
