import Foundation
import WuhuAI

// MARK: - Runner result types

/// Result of a bash command execution.
public struct BashResult: Sendable, Hashable, Codable {
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

/// Durable identity and execution parameters for a resumable bash task.
public struct BashTaskRequest: Sendable, Hashable, Codable {
  public var taskID: String
  public var runnerID: RunnerID
  public var command: String
  public var cwd: String
  public var timeout: Double?

  public init(
    taskID: String,
    runnerID: RunnerID,
    command: String,
    cwd: String,
    timeout: Double? = nil,
  ) {
    self.taskID = taskID
    self.runnerID = runnerID
    self.command = command
    self.cwd = cwd
    self.timeout = timeout
  }
}

public typealias BashStreamCursor = Int

public enum BashStreamPayload: Sendable, Hashable, Codable {
  case output(String)
  case finished(BashResult)

  private enum CodingKeys: String, CodingKey {
    case kind
    case output
    case result
  }

  private enum Kind: String, Codable {
    case output
    case finished
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .output:
      self = try .output(container.decode(String.self, forKey: .output))
    case .finished:
      self = try .finished(container.decode(BashResult.self, forKey: .result))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .output(output):
      try container.encode(Kind.output, forKey: .kind)
      try container.encode(output, forKey: .output)
    case let .finished(result):
      try container.encode(Kind.finished, forKey: .kind)
      try container.encode(result, forKey: .result)
    }
  }
}

public struct BashStreamEvent: Sendable, Hashable, Codable {
  public var cursor: BashStreamCursor
  public var payload: BashStreamPayload

  public init(cursor: BashStreamCursor, payload: BashStreamPayload) {
    self.cursor = cursor
    self.payload = payload
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

public struct MaterializeRequest: Sendable, Hashable, Codable {
  public var templatePath: String
  public var destinationPath: String
  public var startupScript: String?

  public init(templatePath: String, destinationPath: String, startupScript: String? = nil) {
    self.templatePath = templatePath
    self.destinationPath = destinationPath
    self.startupScript = startupScript
  }
}

public struct MaterializeResponse: Sendable, Hashable, Codable {
  public var workspacePath: String

  public init(workspacePath: String) {
    self.workspacePath = workspacePath
  }
}

public struct RunnerWireError: Error, Sendable, Hashable, Codable, CustomStringConvertible {
  public var message: String

  public init(_ message: String) {
    self.message = message
  }

  public var description: String {
    message
  }

  public init(from decoder: any Decoder) throws {
    message = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(message)
  }
}

// MARK: - Runner protocol

/// Minimal execution proxy for filesystem operations and process execution.
///
/// `LocalRunner` implements this directly on the local machine.
/// Remote runners can implement the same protocol over HTTP or other transports.
public protocol Runner: Actor, Sendable {
  nonisolated var id: RunnerID { get }

  /// -- Process execution --
  func startBash(taskID: String, command: String, cwd: String, timeout: TimeInterval?) async throws
  func streamBash(taskID: String, after cursor: BashStreamCursor?) async throws -> AsyncThrowingStream<BashStreamEvent, Error>
  func ackBash(taskID: String, through cursor: BashStreamCursor) async throws
  func killBash(taskID: String) async throws
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

public extension Runner {
  func runBash(command: String, cwd: String, timeout: TimeInterval?) async throws -> BashResult {
    let taskID = UUID().uuidString.lowercased()
    try await startBash(taskID: taskID, command: command, cwd: cwd, timeout: timeout)

    let stream = try await streamBash(taskID: taskID, after: nil)
    for try await event in stream {
      try await ackBash(taskID: taskID, through: event.cursor)
      if case let .finished(result) = event.payload {
        return result
      }
    }

    throw RunnerError.requestFailed(message: "Bash stream ended without a terminal result")
  }
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
