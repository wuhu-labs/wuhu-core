import Foundation
import PiAI

// MARK: - Runner result types

/// Result of a bash command execution.
public struct BashResult: Sendable, Hashable {
  public var exitCode: Int32
  public var output: String
  public var timedOut: Bool
  public var terminated: Bool
  /// Path to the full output file on the runner's filesystem.
  /// Only meaningful for local runner; remote runners may not expose this.
  public var fullOutputPath: String?

  public init(
    exitCode: Int32,
    output: String,
    timedOut: Bool,
    terminated: Bool,
    fullOutputPath: String? = nil,
  ) {
    self.exitCode = exitCode
    self.output = output
    self.timedOut = timedOut
    self.terminated = terminated
    self.fullOutputPath = fullOutputPath
  }
}

/// File existence check result.
public enum FileExistence: String, Sendable, Hashable, Codable {
  case notFound
  case file
  case directory
}

/// Entry in a directory listing.
public struct DirectoryEntry: Sendable, Hashable, Codable {
  public var name: String
  public var isDirectory: Bool

  public init(name: String, isDirectory: Bool) {
    self.name = name
    self.isDirectory = isDirectory
  }
}

/// Entry from recursive directory enumeration.
public struct EnumeratedEntry: Sendable, Hashable, Codable {
  public var relativePath: String
  public var absolutePath: String
  public var isDirectory: Bool

  public init(relativePath: String, absolutePath: String, isDirectory: Bool) {
    self.relativePath = relativePath
    self.absolutePath = absolutePath
    self.isDirectory = isDirectory
  }
}

// MARK: - Find/Grep result types

/// A single match from a find operation.
public struct FindEntry: Sendable, Hashable, Codable {
  public var relativePath: String

  public init(relativePath: String) {
    self.relativePath = relativePath
  }
}

/// A single match from a grep operation.
public struct GrepMatch: Sendable, Hashable, Codable {
  /// File path relative to the search root.
  public var file: String
  /// 1-indexed line number of the match.
  public var lineNumber: Int
  /// The matched line content (may be truncated).
  public var line: String
  /// Whether this is a context line (not the match itself).
  public var isContext: Bool

  public init(file: String, lineNumber: Int, line: String, isContext: Bool = false) {
    self.file = file
    self.lineNumber = lineNumber
    self.line = line
    self.isContext = isContext
  }
}

/// Parameters for a find operation.
public struct FindParams: Sendable, Hashable, Codable {
  public var root: String
  public var pattern: String
  public var limit: Int

  public init(root: String, pattern: String, limit: Int = 1000) {
    self.root = root
    self.pattern = pattern
    self.limit = limit
  }
}

/// Parameters for a grep operation.
public struct GrepParams: Sendable, Hashable, Codable {
  public var root: String
  public var pattern: String
  public var glob: String?
  public var ignoreCase: Bool
  public var literal: Bool
  public var contextLines: Int
  public var limit: Int

  public init(
    root: String,
    pattern: String,
    glob: String? = nil,
    ignoreCase: Bool = false,
    literal: Bool = false,
    contextLines: Int = 0,
    limit: Int = 100,
  ) {
    self.root = root
    self.pattern = pattern
    self.glob = glob
    self.ignoreCase = ignoreCase
    self.literal = literal
    self.contextLines = contextLines
    self.limit = limit
  }
}

/// Result of a find operation.
public struct FindResult: Sendable, Hashable, Codable {
  public var entries: [FindEntry]
  public var totalBeforeLimit: Int

  public init(entries: [FindEntry], totalBeforeLimit: Int) {
    self.entries = entries
    self.totalBeforeLimit = totalBeforeLimit
  }
}

/// Result of a grep operation.
public struct GrepResult: Sendable, Hashable, Codable {
  public var matches: [GrepMatch]
  public var matchCount: Int
  public var limitReached: Bool
  public var linesTruncated: Bool

  public init(matches: [GrepMatch], matchCount: Int, limitReached: Bool, linesTruncated: Bool) {
    self.matches = matches
    self.matchCount = matchCount
    self.limitReached = limitReached
    self.linesTruncated = linesTruncated
  }
}

// MARK: - Runner protocol

/// Minimal execution proxy for filesystem operations and process execution.
///
/// `LocalRunner` implements this directly on the local machine.
/// `RemoteRunnerClient` implements this by forwarding calls over WebSocket
/// to a `RunnerServerHandler` wrapping any `Runner`.
public protocol Runner: Actor, Sendable {
  nonisolated var id: RunnerID { get }

  /// -- Process execution --
  func runBash(command: String, cwd: String, timeout: TimeInterval?) async throws -> BashResult

  // -- File I/O --
  func readData(path: String) async throws -> Data
  func readString(path: String, encoding: String.Encoding) async throws -> String
  func writeData(path: String, data: Data, createIntermediateDirectories: Bool) async throws
  func writeString(path: String, content: String, createIntermediateDirectories: Bool, encoding: String.Encoding) async throws
  func exists(path: String) async throws -> FileExistence
  func listDirectory(path: String) async throws -> [DirectoryEntry]
  func enumerateDirectory(root: String) async throws -> [EnumeratedEntry]
  func createDirectory(path: String, withIntermediateDirectories: Bool) async throws

  // -- Search --
  func find(params: FindParams) async throws -> FindResult
  func grep(params: GrepParams) async throws -> GrepResult

  /// -- Workspace materialization --
  func materialize(params: MaterializeRequest) async throws -> MaterializeResponse
}

// MARK: - Runner errors

public enum RunnerError: Error, Sendable, CustomStringConvertible {
  case disconnected(runnerName: String)
  case requestFailed(message: String)
  case fileNotFound(path: String)
  case notADirectory(path: String)
  case timeout(message: String)

  public var description: String {
    switch self {
    case let .disconnected(name):
      "Runner '\(name)' is disconnected"
    case let .requestFailed(message):
      "Runner request failed: \(message)"
    case let .fileNotFound(path):
      "File not found: \(path)"
    case let .notADirectory(path):
      "Not a directory: \(path)"
    case let .timeout(message):
      "Runner timeout: \(message)"
    }
  }
}
