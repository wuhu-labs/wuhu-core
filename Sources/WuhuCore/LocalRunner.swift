import Dependencies
import Foundation

/// Local runner — executes everything on the local machine.
/// Uses the `FileIO` dependency for filesystem operations, preserving
/// testability via `InMemoryFileIO`.
public actor LocalRunner: Runner {
  public nonisolated let id: RunnerID = .local

  public init() {}

  // MARK: - Process execution

  public func runBash(command: String, cwd: String, timeout: TimeInterval?) async throws -> BashResult {
    try await LocalBash.run(command: command, cwd: cwd, timeoutSeconds: timeout)
  }

  // MARK: - File I/O

  public func readData(path: String) async throws -> Data {
    @Dependency(\.fileIO) var fileIO
    return try fileIO.readData(path: path)
  }

  public func readString(path: String, encoding: String.Encoding) async throws -> String {
    @Dependency(\.fileIO) var fileIO
    return try fileIO.readString(path: path, encoding: encoding)
  }

  public func writeData(path: String, data: Data, createIntermediateDirectories: Bool) async throws {
    @Dependency(\.fileIO) var fileIO
    if createIntermediateDirectories {
      let dir = (path as NSString).deletingLastPathComponent
      try fileIO.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    try fileIO.writeData(path: path, data: data, atomically: true)
  }

  public func writeString(path: String, content: String, createIntermediateDirectories: Bool, encoding: String.Encoding) async throws {
    @Dependency(\.fileIO) var fileIO
    if createIntermediateDirectories {
      let dir = (path as NSString).deletingLastPathComponent
      try fileIO.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    try fileIO.writeString(path: path, content: content, atomically: true, encoding: encoding)
  }

  public func exists(path: String) async throws -> FileExistence {
    @Dependency(\.fileIO) var fileIO
    let (exists, isDir) = fileIO.existsAndIsDirectory(path: path)
    if !exists { return .notFound }
    return isDir ? .directory : .file
  }

  public func listDirectory(path: String) async throws -> [DirectoryEntry] {
    @Dependency(\.fileIO) var fileIO
    let (dirExists, isDir) = fileIO.existsAndIsDirectory(path: path)
    guard dirExists else { throw RunnerError.fileNotFound(path: path) }
    guard isDir else { throw RunnerError.notADirectory(path: path) }

    let entries = try fileIO.contentsOfDirectory(atPath: path)
    return entries.map { name in
      let full = (path as NSString).appendingPathComponent(name)
      let (_, isEntryDir) = fileIO.existsAndIsDirectory(path: full)
      return DirectoryEntry(name: name, isDirectory: isEntryDir)
    }
  }

  public func enumerateDirectory(root: String) async throws -> [EnumeratedEntry] {
    @Dependency(\.fileIO) var fileIO
    let raw = try fileIO.enumerateDirectory(atPath: root)
    return raw.map { EnumeratedEntry(relativePath: $0.relativePath, absolutePath: $0.absolutePath, isDirectory: $0.isDirectory) }
  }

  public func createDirectory(path: String, withIntermediateDirectories: Bool) async throws {
    @Dependency(\.fileIO) var fileIO
    try fileIO.createDirectory(atPath: path, withIntermediateDirectories: withIntermediateDirectories)
  }
}
