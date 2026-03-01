import Foundation

/// In-memory implementation of ``FileIO`` for use in tests. Files and
/// directories are stored in dictionaries; no real filesystem is touched.
public final class InMemoryFileIO: FileIO, @unchecked Sendable {
  private let lock = NSLock()
  private var files: [String: Data] = [:]
  private var directories: Set<String> = ["/"]

  public init() {}

  // MARK: - Test helpers

  /// Seed a file at the given absolute path, creating parent directories as needed.
  public func seedFile(path: String, data: Data) {
    lock.lock()
    defer { lock.unlock() }
    ensureParentDirectories(path)
    files[path] = data
  }

  /// Seed a text file at the given absolute path.
  public func seedFile(path: String, content: String, encoding: String.Encoding = .utf8) {
    seedFile(path: path, data: content.data(using: encoding) ?? Data())
  }

  /// Seed an empty directory at the given absolute path.
  public func seedDirectory(path: String) {
    lock.lock()
    defer { lock.unlock() }
    ensureParentDirectories(path)
    directories.insert(normalized(path))
  }

  /// Read back a file from the store (for test assertions).
  public func storedData(path: String) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return files[normalized(path)]
  }

  /// Read back a file as a string (for test assertions).
  ///
  /// Uses `String(decoding:as:)` for UTF-8 to preserve the BOM character
  /// (`U+FEFF`) if present in the data. `String(data:encoding:)` silently
  /// strips it, which would cause round-trip mismatches in tests that verify
  /// BOM preservation.
  public func storedString(path: String, encoding: String.Encoding = .utf8) -> String? {
    guard let data = storedData(path: path) else { return nil }
    if encoding == .utf8 {
      return String(decoding: data, as: UTF8.self)
    }
    return String(data: data, encoding: encoding)
  }

  // MARK: - FileIO conformance

  public func readData(path: String) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard let data = files[normalized(path)] else {
      throw InMemoryFileIOError.fileNotFound(path)
    }
    return data
  }

  public func readString(path: String, encoding: String.Encoding) throws -> String {
    let data = try readData(path: path)
    guard let str = String(data: data, encoding: encoding) else {
      throw InMemoryFileIOError.encodingError(path)
    }
    return str
  }

  public func writeData(path: String, data: Data, atomically _: Bool) throws {
    lock.lock()
    defer { lock.unlock() }
    ensureParentDirectories(path)
    files[normalized(path)] = data
  }

  public func writeString(path: String, content: String, atomically: Bool, encoding: String.Encoding) throws {
    guard let data = content.data(using: encoding) else {
      throw InMemoryFileIOError.encodingError(path)
    }
    try writeData(path: path, data: data, atomically: atomically)
  }

  public func exists(path: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let p = normalized(path)
    return files[p] != nil || directories.contains(p)
  }

  public func existsAndIsDirectory(path: String) -> (exists: Bool, isDirectory: Bool) {
    lock.lock()
    defer { lock.unlock() }
    let p = normalized(path)
    if directories.contains(p) { return (true, true) }
    if files[p] != nil { return (true, false) }
    return (false, false)
  }

  public func contentsOfDirectory(atPath path: String) throws -> [String] {
    lock.lock()
    defer { lock.unlock() }
    let dir = normalized(path)
    guard directories.contains(dir) else {
      throw InMemoryFileIOError.directoryNotFound(path)
    }

    let prefix = dir == "/" ? "/" : dir + "/"
    var entries = Set<String>()

    for filePath in files.keys {
      if filePath.hasPrefix(prefix) {
        let remainder = String(filePath.dropFirst(prefix.count))
        if let firstComponent = remainder.split(separator: "/").first {
          entries.insert(String(firstComponent))
        }
      }
    }
    for dirPath in directories {
      if dirPath.hasPrefix(prefix) {
        let remainder = String(dirPath.dropFirst(prefix.count))
        if !remainder.isEmpty, let firstComponent = remainder.split(separator: "/").first {
          entries.insert(String(firstComponent))
        }
      }
    }

    return Array(entries)
  }

  public func createDirectory(atPath path: String, withIntermediateDirectories: Bool) throws {
    lock.lock()
    defer { lock.unlock() }
    let p = normalized(path)
    if directories.contains(p) { return }

    if withIntermediateDirectories {
      ensureParentDirectories(p)
      directories.insert(p)
    } else {
      let parent = parentPath(p)
      guard directories.contains(parent) else {
        throw InMemoryFileIOError.directoryNotFound(parent)
      }
      directories.insert(p)
    }
  }

  public func enumerateDirectory(atPath root: String) throws -> [(relativePath: String, absolutePath: String, isDirectory: Bool)] {
    lock.lock()
    defer { lock.unlock() }
    let rootNorm = normalized(root)
    guard directories.contains(rootNorm) else {
      throw InMemoryFileIOError.directoryNotFound(root)
    }

    let prefix = rootNorm == "/" ? "/" : rootNorm + "/"
    var results: [(relativePath: String, absolutePath: String, isDirectory: Bool)] = []

    // Gather directories (excluding root itself).
    for dirPath in directories.sorted() {
      if dirPath.hasPrefix(prefix) {
        let rel = String(dirPath.dropFirst(prefix.count))
        if !rel.isEmpty {
          results.append((relativePath: rel, absolutePath: dirPath, isDirectory: true))
        }
      }
    }

    // Gather files.
    for filePath in files.keys.sorted() {
      if filePath.hasPrefix(prefix) {
        let rel = String(filePath.dropFirst(prefix.count))
        if !rel.isEmpty {
          results.append((relativePath: rel, absolutePath: filePath, isDirectory: false))
        }
      }
    }

    return results
  }

  // MARK: - Internal helpers

  private func normalized(_ path: String) -> String {
    // Normalize: resolve .. and ., ensure leading /
    let url = URL(fileURLWithPath: path).standardizedFileURL
    return url.path
  }

  private func parentPath(_ path: String) -> String {
    let ns = path as NSString
    let parent = ns.deletingLastPathComponent
    return parent.isEmpty ? "/" : parent
  }

  /// Ensure all parent directories exist for a given path (must be called under lock).
  private func ensureParentDirectories(_ path: String) {
    let p = normalized(path)
    var current = parentPath(p)
    var stack: [String] = []
    while !directories.contains(current), current != "/" {
      stack.append(current)
      current = parentPath(current)
    }
    for dir in stack.reversed() {
      directories.insert(dir)
    }
    if !directories.contains("/") {
      directories.insert("/")
    }
  }
}

// MARK: - Errors

public enum InMemoryFileIOError: Error, Sendable, CustomStringConvertible {
  case fileNotFound(String)
  case directoryNotFound(String)
  case encodingError(String)

  public var description: String {
    switch self {
    case let .fileNotFound(p): "File not found: \(p)"
    case let .directoryNotFound(p): "Directory not found: \(p)"
    case let .encodingError(p): "Encoding error: \(p)"
    }
  }
}
