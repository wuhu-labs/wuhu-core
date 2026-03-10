import Foundation

/// Filesystem-backed ``DataBucket``. Stores data as files under a root directory.
///
/// Keys are treated as relative paths — slashes create subdirectories.
public struct LocalDataBucket: DataBucket, Sendable {
  private let rootURL: URL

  public init(rootDirectory: String) {
    rootURL = URL(fileURLWithPath: rootDirectory, isDirectory: true)
  }

  public func write(key: String, data: Data) async throws {
    let fileURL = rootURL.appendingPathComponent(key)
    let dirURL = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
    try data.write(to: fileURL, options: [.atomic])
  }

  public func read(key: String) async throws -> Data? {
    let fileURL = rootURL.appendingPathComponent(key)
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return try Data(contentsOf: fileURL)
  }

  public func exists(key: String) async throws -> Bool {
    let fileURL = rootURL.appendingPathComponent(key)
    return FileManager.default.fileExists(atPath: fileURL.path)
  }
}
