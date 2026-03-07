import Foundation

// MARK: - Request payloads

public struct HelloRequest: Sendable, Hashable, Codable {
  public var serverName: String
  public var version: Int

  public init(serverName: String, version: Int) {
    self.serverName = serverName
    self.version = version
  }
}

public struct BashRequest: Sendable, Hashable, Codable {
  public var command: String
  public var cwd: String
  public var timeout: Double?
  /// Opaque tag for cancellation. The runner tracks active bash executions
  /// by this tag so the server can cancel them via `MuxRunnerOp.cancel`.
  /// Typically the tool call ID from the agent loop.
  public var tag: String?

  public init(command: String, cwd: String, timeout: Double? = nil, tag: String? = nil) {
    self.command = command
    self.cwd = cwd
    self.timeout = timeout
    self.tag = tag
  }
}

public struct ReadRequest: Sendable, Hashable, Codable {
  public var path: String
  /// If true, response includes binary data.
  /// If false (default), response includes string content.
  public var binary: Bool

  public init(path: String, binary: Bool = false) {
    self.path = path
    self.binary = binary
  }
}

public struct WriteRequest: Sendable, Hashable, Codable {
  public var path: String
  public var createDirs: Bool
  /// For text writes, content is in this field.
  /// For binary writes, this is nil and data follows on the stream.
  public var content: String?

  public init(path: String, createDirs: Bool = true, content: String? = nil) {
    self.path = path
    self.createDirs = createDirs
    self.content = content
  }
}

public struct ExistsRequest: Sendable, Hashable, Codable {
  public var path: String
  public init(path: String) {
    self.path = path
  }
}

public struct LsRequest: Sendable, Hashable, Codable {
  public var path: String
  public init(path: String) {
    self.path = path
  }
}

public struct EnumerateRequest: Sendable, Hashable, Codable {
  public var root: String
  public init(root: String) {
    self.root = root
  }
}

public struct MkdirRequest: Sendable, Hashable, Codable {
  public var path: String
  public var recursive: Bool
  public init(path: String, recursive: Bool = true) {
    self.path = path
    self.recursive = recursive
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

// FindParams and GrepParams are defined in Runner.swift.

// MARK: - Cancel request

/// Request to cancel a running bash process on the runner.
public struct CancelRequest: Sendable, Hashable, Codable {
  /// Tag identifying the bash execution to cancel.
  /// Matches the `tag` field from the originating `BashRequest`.
  public var tag: String

  public init(tag: String) {
    self.tag = tag
  }
}

/// Response to a cancel request (acknowledgement).
public struct CancelResponse: Sendable, Hashable, Codable {
  public var cancelled: Bool
  public init(cancelled: Bool) {
    self.cancelled = cancelled
  }
}

// MARK: - Response payloads

public struct HelloResponse: Sendable, Hashable, Codable {
  public var runnerName: String
  public var version: Int

  public init(runnerName: String, version: Int) {
    self.runnerName = runnerName
    self.version = version
  }
}

public struct ReadResponse: Sendable, Hashable, Codable {
  public var content: String?
  public var size: Int

  public init(content: String? = nil, size: Int) {
    self.content = content
    self.size = size
  }
}

public struct WriteResponse: Sendable, Hashable, Codable {
  public var bytesWritten: Int
  public init(bytesWritten: Int) {
    self.bytesWritten = bytesWritten
  }
}

public struct ExistsResponse: Sendable, Hashable, Codable {
  public var existence: FileExistence
  public init(existence: FileExistence) {
    self.existence = existence
  }
}

public struct LsResponse: Sendable, Hashable, Codable {
  public var entries: [DirectoryEntry]
  public init(entries: [DirectoryEntry]) {
    self.entries = entries
  }
}

public struct EnumerateResponse: Sendable, Hashable, Codable {
  public var entries: [EnumeratedEntry]
  public init(entries: [EnumeratedEntry]) {
    self.entries = entries
  }
}

public struct MkdirResponse: Sendable, Hashable, Codable {
  public init() {}
}

public struct MaterializeResponse: Sendable, Hashable, Codable {
  public var workspacePath: String
  public init(workspacePath: String) {
    self.workspacePath = workspacePath
  }
}

// MARK: - Wire error type

/// Error type used in Result values for runner dispatch.
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
    var c = encoder.singleValueContainer()
    try c.encode(message)
  }
}

// MARK: - Internal dispatch enums

/// A runner request, used internally by `RunnerServerHandler` for dispatch.
public enum RunnerRequest: Sendable, Hashable {
  case hello(HelloRequest)
  case bash(id: String, BashRequest)
  case read(id: String, ReadRequest)
  case write(id: String, WriteRequest)
  case exists(id: String, ExistsRequest)
  case ls(id: String, LsRequest)
  case enumerate(id: String, EnumerateRequest)
  case mkdir(id: String, MkdirRequest)
  case find(id: String, FindParams)
  case grep(id: String, GrepParams)
  case materialize(id: String, MaterializeRequest)
  case cancel(id: String, CancelRequest)
}

/// A runner response, used internally by `RunnerServerHandler` for dispatch.
public enum RunnerResponse: Sendable {
  case hello(HelloResponse)
  case bash(id: String, Result<BashResult, RunnerWireError>)
  case read(id: String, Result<ReadResponse, RunnerWireError>)
  case write(id: String, Result<WriteResponse, RunnerWireError>)
  case exists(id: String, Result<ExistsResponse, RunnerWireError>)
  case ls(id: String, Result<LsResponse, RunnerWireError>)
  case enumerate(id: String, Result<EnumerateResponse, RunnerWireError>)
  case mkdir(id: String, Result<MkdirResponse, RunnerWireError>)
  case find(id: String, Result<FindResult, RunnerWireError>)
  case grep(id: String, Result<GrepResult, RunnerWireError>)
  case materialize(id: String, Result<MaterializeResponse, RunnerWireError>)
  case cancel(id: String, Result<CancelResponse, RunnerWireError>)

  public var responseID: String? {
    switch self {
    case .hello: nil
    case let .bash(id, _): id
    case let .read(id, _): id
    case let .write(id, _): id
    case let .exists(id, _): id
    case let .ls(id, _): id
    case let .enumerate(id, _): id
    case let .mkdir(id, _): id
    case let .find(id, _): id
    case let .grep(id, _): id
    case let .materialize(id, _): id
    case let .cancel(id, _): id
    }
  }
}

// MARK: - BashResult Codable

extension BashResult: Codable {
  enum CodingKeys: String, CodingKey {
    case exitCode, output, timedOut, terminated, fullOutputPath
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    exitCode = try c.decode(Int32.self, forKey: .exitCode)
    output = try c.decode(String.self, forKey: .output)
    timedOut = try c.decode(Bool.self, forKey: .timedOut)
    terminated = try c.decode(Bool.self, forKey: .terminated)
    fullOutputPath = try c.decodeIfPresent(String.self, forKey: .fullOutputPath)
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(exitCode, forKey: .exitCode)
    try c.encode(output, forKey: .output)
    try c.encode(timedOut, forKey: .timedOut)
    try c.encode(terminated, forKey: .terminated)
    try c.encodeIfPresent(fullOutputPath, forKey: .fullOutputPath)
  }
}
