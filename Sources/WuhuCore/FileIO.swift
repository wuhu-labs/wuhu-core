import Foundation

// MARK: - FileIO protocol

/// Abstracts all filesystem operations used by coding agent tools, enabling
/// in-memory implementations for testing.
public protocol FileIO: Sendable {
  /// Read file contents as raw bytes.
  func readData(path: String) throws -> Data

  /// Read file contents as a string.
  func readString(path: String, encoding: String.Encoding) throws -> String

  /// Write raw bytes to a file.
  func writeData(path: String, data: Data, atomically: Bool) throws

  /// Write a string to a file.
  func writeString(path: String, content: String, atomically: Bool, encoding: String.Encoding) throws

  /// Check if a path exists.
  func exists(path: String) -> Bool

  /// Check if a path exists and whether it is a directory.
  func existsAndIsDirectory(path: String) -> (exists: Bool, isDirectory: Bool)

  /// List the immediate contents of a directory (basenames only).
  func contentsOfDirectory(atPath path: String) throws -> [String]

  /// Create a directory, optionally creating intermediate directories.
  func createDirectory(atPath path: String, withIntermediateDirectories: Bool) throws

  /// Walk a directory tree, returning a flat enumerator-like sequence.
  /// Each element is `(relativePath, absolutePath, isDirectory)`.
  func enumerateDirectory(atPath root: String) throws -> [(relativePath: String, absolutePath: String, isDirectory: Bool)]
}

// MARK: - FileIOAttributes

/// Captures what tools need from file metadata.
public struct FileIOAttributes: Sendable, Hashable {
  public var size: Int
  public var isDirectory: Bool
  public var modificationDate: Date?

  public init(size: Int, isDirectory: Bool, modificationDate: Date? = nil) {
    self.size = size
    self.isDirectory = isDirectory
    self.modificationDate = modificationDate
  }
}
