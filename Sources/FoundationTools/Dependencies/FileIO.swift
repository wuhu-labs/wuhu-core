import Dependencies
import DependenciesMacros
import Foundation

// MARK: - FileStat

public struct FileStat: Sendable, Hashable {
  public enum NodeType: Sendable, Hashable {
    case file
    case directory
    case symlink
    case other
  }

  public var type: NodeType
  public var size: Int
  public var modificationDate: Date?

  public init(type: NodeType, size: Int, modificationDate: Date? = nil) {
    self.type = type
    self.size = size
    self.modificationDate = modificationDate
  }
}

// MARK: - DirectoryEntry

public struct DirectoryEntry: Sendable, Hashable {
  public var name: String
  public var type: FileStat.NodeType

  public init(name: String, type: FileStat.NodeType) {
    self.name = name
    self.type = type
  }
}

// MARK: - FileHandle

@DependencyClient
public struct FileHandle: ~Copyable {
  public var read: (_ length: Int) async throws -> Data
  public var seek: (_ offset: Int) async throws -> Void
  public var close: () async throws -> Void
}

// MARK: - FileIO

@DependencyClient
public struct FileIO: Sendable {
  /// Metadata for a path. Follows symlinks.
  public var stat: @Sendable (_ path: String) async throws -> FileStat

  /// Open a file handle.
  public var open: @Sendable (_ path: String) async throws -> FileHandle

  /// Write raw bytes to a file. Creates parent directories if needed.
  public var write: @Sendable (_ path: String, _ data: Data) async throws -> Void

  /// List the immediate contents of a directory.
  public var list: @Sendable (_ path: String) async throws -> [DirectoryEntry]

  /// Create a directory, optionally creating intermediate directories.
  public var mkdir: @Sendable (_ path: String) async throws -> Void

  public var delete: @Sendable (_ path: String) async throws -> Void

  /// Create a symbolic link at `path` pointing to `target`.
  public var link: @Sendable (_ path: String, _ target: String) async throws -> Void
}

public extension FileIO {
  /// Scoped access to a file handle. Automatically closes on exit.
  func withFileHandle<T: Sendable>(
    _ path: String,
    _ body: (borrowing FileHandle) async throws -> T,
  ) async throws -> T {
    let handle = try await open(path)
    do {
      let result = try await body(handle)
      try await handle.close()
      return result
    } catch {
      try? await handle.close()
      throw error
    }
  }
}

extension FileIO: TestDependencyKey {
  public static let testValue: FileIO = .init()
}
