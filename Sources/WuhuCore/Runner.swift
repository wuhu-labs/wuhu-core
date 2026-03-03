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

// MARK: - Runner protocol

/// Minimal execution proxy for filesystem operations and process execution.
///
/// `LocalRunner` implements this directly on the local machine.
/// `RemoteRunnerClient` implements this by forwarding calls over WebSocket
/// to a `RunnerServerHandler` wrapping any `Runner`.
public protocol Runner: Actor, Sendable {
  nonisolated var id: RunnerID { get }

  // -- Process execution --
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
