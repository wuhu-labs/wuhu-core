import Foundation

/// Protocol for storing raw LLM HTTP payloads (request bodies, SSE responses).
///
/// Implementations write opaque data blobs keyed by a relative path.
/// The `tracedStreamFn` wrapper stores the path in OTel span attributes so
/// payloads can be retrieved later for debugging.
public protocol LLMPayloadStore: Sendable {
  /// Write data to the store at the given relative path.
  /// Creates intermediate directories/prefixes as needed.
  func write(path: String, data: Data) async throws

  /// Read data back from the store. Returns nil if the path doesn't exist.
  func read(path: String) async throws -> Data?
}

/// Local filesystem implementation of ``LLMPayloadStore``.
///
/// Stores payloads under a root directory, preserving the relative path structure.
public struct LocalLLMPayloadStore: LLMPayloadStore {
  private let rootURL: URL

  public init(rootDirectory: String) {
    rootURL = URL(fileURLWithPath: rootDirectory, isDirectory: true)
  }

  public func write(path: String, data: Data) async throws {
    let fileURL = rootURL.appendingPathComponent(path)
    let dirURL = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
    try data.write(to: fileURL, options: [.atomic])
  }

  public func read(path: String) async throws -> Data? {
    let fileURL = rootURL.appendingPathComponent(path)
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return try Data(contentsOf: fileURL)
  }
}
