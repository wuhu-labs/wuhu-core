import Foundation
import PiAI

// MARK: - Runner wire protocol

/// Request message sent from server to runner over WebSocket.
public enum RunnerRequest: Sendable, Hashable, Codable {
  case hello(serverName: String, version: Int)

  case bash(id: String, command: String, cwd: String, timeout: Double?)
  case readFile(id: String, path: String)
  case writeFile(id: String, path: String, base64Data: String, createDirs: Bool)
  case writeString(id: String, path: String, content: String, createDirs: Bool)
  case exists(id: String, path: String)
  case listDirectory(id: String, path: String)
  case enumerateDirectory(id: String, root: String)
  case createDirectory(id: String, path: String, withIntermediateDirectories: Bool)
  case readString(id: String, path: String)

  enum CodingKeys: String, CodingKey {
    case type, id, serverName, version
    case command, cwd, timeout, path, base64Data, content, createDirs, root
    case withIntermediateDirectories
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let type = try c.decode(String.self, forKey: .type)
    switch type {
    case "hello":
      self = try .hello(
        serverName: c.decode(String.self, forKey: .serverName),
        version: c.decode(Int.self, forKey: .version),
      )
    case "bash":
      self = try .bash(
        id: c.decode(String.self, forKey: .id),
        command: c.decode(String.self, forKey: .command),
        cwd: c.decode(String.self, forKey: .cwd),
        timeout: c.decodeIfPresent(Double.self, forKey: .timeout),
      )
    case "read_file":
      self = try .readFile(id: c.decode(String.self, forKey: .id), path: c.decode(String.self, forKey: .path))
    case "write_file":
      self = try .writeFile(
        id: c.decode(String.self, forKey: .id),
        path: c.decode(String.self, forKey: .path),
        base64Data: c.decode(String.self, forKey: .base64Data),
        createDirs: c.decode(Bool.self, forKey: .createDirs),
      )
    case "write_string":
      self = try .writeString(
        id: c.decode(String.self, forKey: .id),
        path: c.decode(String.self, forKey: .path),
        content: c.decode(String.self, forKey: .content),
        createDirs: c.decode(Bool.self, forKey: .createDirs),
      )
    case "exists":
      self = try .exists(id: c.decode(String.self, forKey: .id), path: c.decode(String.self, forKey: .path))
    case "list_directory":
      self = try .listDirectory(id: c.decode(String.self, forKey: .id), path: c.decode(String.self, forKey: .path))
    case "enumerate_directory":
      self = try .enumerateDirectory(id: c.decode(String.self, forKey: .id), root: c.decode(String.self, forKey: .root))
    case "create_directory":
      self = try .createDirectory(
        id: c.decode(String.self, forKey: .id),
        path: c.decode(String.self, forKey: .path),
        withIntermediateDirectories: c.decode(Bool.self, forKey: .withIntermediateDirectories),
      )
    case "read_string":
      self = try .readString(id: c.decode(String.self, forKey: .id), path: c.decode(String.self, forKey: .path))
    default:
      throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown runner request type: \(type)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .hello(serverName, version):
      try c.encode("hello", forKey: .type)
      try c.encode(serverName, forKey: .serverName)
      try c.encode(version, forKey: .version)
    case let .bash(id, command, cwd, timeout):
      try c.encode("bash", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encode(command, forKey: .command)
      try c.encode(cwd, forKey: .cwd)
      try c.encodeIfPresent(timeout, forKey: .timeout)
    case let .readFile(id, path):
      try c.encode("read_file", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encode(path, forKey: .path)
    case let .writeFile(id, path, base64Data, createDirs):
      try c.encode("write_file", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encode(path, forKey: .path)
      try c.encode(base64Data, forKey: .base64Data)
      try c.encode(createDirs, forKey: .createDirs)
    case let .writeString(id, path, content, createDirs):
      try c.encode("write_string", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encode(path, forKey: .path)
      try c.encode(content, forKey: .content)
      try c.encode(createDirs, forKey: .createDirs)
    case let .exists(id, path):
      try c.encode("exists", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encode(path, forKey: .path)
    case let .listDirectory(id, path):
      try c.encode("list_directory", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encode(path, forKey: .path)
    case let .enumerateDirectory(id, root):
      try c.encode("enumerate_directory", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encode(root, forKey: .root)
    case let .createDirectory(id, path, withIntermediateDirectories):
      try c.encode("create_directory", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encode(path, forKey: .path)
      try c.encode(withIntermediateDirectories, forKey: .withIntermediateDirectories)
    case let .readString(id, path):
      try c.encode("read_string", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encode(path, forKey: .path)
    }
  }

  /// The correlation ID for request/response matching. Nil for `hello`.
  public var requestID: String? {
    switch self {
    case .hello: nil
    case let .bash(id, _, _, _): id
    case let .readFile(id, _): id
    case let .writeFile(id, _, _, _): id
    case let .writeString(id, _, _, _): id
    case let .exists(id, _): id
    case let .listDirectory(id, _): id
    case let .enumerateDirectory(id, _): id
    case let .createDirectory(id, _, _): id
    case let .readString(id, _): id
    }
  }
}

/// Response message sent from runner back to server.
public enum RunnerResponse: Sendable, Codable {
  case hello(runnerName: String, version: Int)

  case bash(id: String, result: BashResult?, error: String?)
  case readFile(id: String, base64Data: String?, error: String?)
  case writeFile(id: String, error: String?)
  case writeString(id: String, error: String?)
  case exists(id: String, existence: FileExistence?, error: String?)
  case listDirectory(id: String, entries: [DirectoryEntry]?, error: String?)
  case enumerateDirectory(id: String, entries: [EnumeratedEntry]?, error: String?)
  case createDirectory(id: String, error: String?)
  case readString(id: String, content: String?, error: String?)

  enum CodingKeys: String, CodingKey {
    case type, id, runnerName, version
    case result, base64Data, error, existence, entries, content
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let type = try c.decode(String.self, forKey: .type)
    switch type {
    case "hello":
      self = try .hello(
        runnerName: c.decode(String.self, forKey: .runnerName),
        version: c.decode(Int.self, forKey: .version),
      )
    case "bash":
      self = try .bash(
        id: c.decode(String.self, forKey: .id),
        result: c.decodeIfPresent(BashResult.self, forKey: .result),
        error: c.decodeIfPresent(String.self, forKey: .error),
      )
    case "read_file":
      self = try .readFile(
        id: c.decode(String.self, forKey: .id),
        base64Data: c.decodeIfPresent(String.self, forKey: .base64Data),
        error: c.decodeIfPresent(String.self, forKey: .error),
      )
    case "write_file":
      self = try .writeFile(id: c.decode(String.self, forKey: .id), error: c.decodeIfPresent(String.self, forKey: .error))
    case "write_string":
      self = try .writeString(id: c.decode(String.self, forKey: .id), error: c.decodeIfPresent(String.self, forKey: .error))
    case "exists":
      self = try .exists(
        id: c.decode(String.self, forKey: .id),
        existence: c.decodeIfPresent(FileExistence.self, forKey: .existence),
        error: c.decodeIfPresent(String.self, forKey: .error),
      )
    case "list_directory":
      self = try .listDirectory(
        id: c.decode(String.self, forKey: .id),
        entries: c.decodeIfPresent([DirectoryEntry].self, forKey: .entries),
        error: c.decodeIfPresent(String.self, forKey: .error),
      )
    case "enumerate_directory":
      self = try .enumerateDirectory(
        id: c.decode(String.self, forKey: .id),
        entries: c.decodeIfPresent([EnumeratedEntry].self, forKey: .entries),
        error: c.decodeIfPresent(String.self, forKey: .error),
      )
    case "create_directory":
      self = try .createDirectory(id: c.decode(String.self, forKey: .id), error: c.decodeIfPresent(String.self, forKey: .error))
    case "read_string":
      self = try .readString(
        id: c.decode(String.self, forKey: .id),
        content: c.decodeIfPresent(String.self, forKey: .content),
        error: c.decodeIfPresent(String.self, forKey: .error),
      )
    default:
      throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown runner response type: \(type)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .hello(runnerName, version):
      try c.encode("hello", forKey: .type)
      try c.encode(runnerName, forKey: .runnerName)
      try c.encode(version, forKey: .version)
    case let .bash(id, result, error):
      try c.encode("bash", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encodeIfPresent(result, forKey: .result)
      try c.encodeIfPresent(error, forKey: .error)
    case let .readFile(id, base64Data, error):
      try c.encode("read_file", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encodeIfPresent(base64Data, forKey: .base64Data)
      try c.encodeIfPresent(error, forKey: .error)
    case let .writeFile(id, error):
      try c.encode("write_file", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encodeIfPresent(error, forKey: .error)
    case let .writeString(id, error):
      try c.encode("write_string", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encodeIfPresent(error, forKey: .error)
    case let .exists(id, existence, error):
      try c.encode("exists", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encodeIfPresent(existence, forKey: .existence)
      try c.encodeIfPresent(error, forKey: .error)
    case let .listDirectory(id, entries, error):
      try c.encode("list_directory", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encodeIfPresent(entries, forKey: .entries)
      try c.encodeIfPresent(error, forKey: .error)
    case let .enumerateDirectory(id, entries, error):
      try c.encode("enumerate_directory", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encodeIfPresent(entries, forKey: .entries)
      try c.encodeIfPresent(error, forKey: .error)
    case let .createDirectory(id, error):
      try c.encode("create_directory", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encodeIfPresent(error, forKey: .error)
    case let .readString(id, content, error):
      try c.encode("read_string", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encodeIfPresent(content, forKey: .content)
      try c.encodeIfPresent(error, forKey: .error)
    }
  }

  /// The correlation ID for request/response matching. Nil for `hello`.
  public var responseID: String? {
    switch self {
    case .hello: nil
    case let .bash(id, _, _): id
    case let .readFile(id, _, _): id
    case let .writeFile(id, _): id
    case let .writeString(id, _): id
    case let .exists(id, _, _): id
    case let .listDirectory(id, _, _): id
    case let .enumerateDirectory(id, _, _): id
    case let .createDirectory(id, _): id
    case let .readString(id, _, _): id
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

/// Current runner wire protocol version.
public let runnerProtocolVersion = 3
