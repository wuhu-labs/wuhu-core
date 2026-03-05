import Foundation

/// Current runner wire protocol version.
public let runnerProtocolVersion = 5

// MARK: - Wire envelope

/// JSON envelope for all text-frame messages.
/// Requests:  {"v":5, "id":"<uuid>", "op":"<op>", "p":{...}}
/// Responses: {"v":5, "id":"<uuid>", "op":"<op>", "ok":{...}}  (success)
///            {"v":5, "id":"<uuid>", "op":"<op>", "err":"..."}  (error)
///
/// Binary frames use a length-prefixed ID for correlation (see `RunnerBinaryFrame`).
/// A binary frame is always a companion to a preceding text-frame request/response
/// that references the same ID.

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

  public init(command: String, cwd: String, timeout: Double? = nil) {
    self.command = command
    self.cwd = cwd
    self.timeout = timeout
  }
}

public struct ReadRequest: Sendable, Hashable, Codable {
  public var path: String
  /// If true, response is a binary frame with raw bytes.
  /// If false (default), response is a JSON text frame with string content.
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
  /// For binary writes, this is nil and data follows in a binary frame.
  public var content: String?

  public init(path: String, createDirs: Bool = true, content: String? = nil) {
    self.path = path
    self.createDirs = createDirs
    self.content = content
  }
}

public struct ExistsRequest: Sendable, Hashable, Codable {
  public var path: String
  public init(path: String) { self.path = path }
}

public struct LsRequest: Sendable, Hashable, Codable {
  public var path: String
  public init(path: String) { self.path = path }
}

public struct EnumerateRequest: Sendable, Hashable, Codable {
  public var root: String
  public init(root: String) { self.root = root }
}

public struct MkdirRequest: Sendable, Hashable, Codable {
  public var path: String
  public var recursive: Bool
  public init(path: String, recursive: Bool = true) {
    self.path = path
    self.recursive = recursive
  }
}

// FindParams and GrepParams are defined in Runner.swift.

// MARK: - Response payloads

public struct HelloResponse: Sendable, Hashable, Codable {
  public var runnerName: String
  public var version: Int

  public init(runnerName: String, version: Int) {
    self.runnerName = runnerName
    self.version = version
  }
}

// BashResult is defined in Runner.swift and already Codable.

public struct ReadResponse: Sendable, Hashable, Codable {
  /// For text reads, the file content as a string.
  /// For binary reads, this is nil — data is in a companion binary frame.
  public var content: String?
  /// Size of the data in bytes (always set).
  public var size: Int

  public init(content: String? = nil, size: Int) {
    self.content = content
    self.size = size
  }
}

public struct WriteResponse: Sendable, Hashable, Codable {
  public var bytesWritten: Int
  public init(bytesWritten: Int) { self.bytesWritten = bytesWritten }
}

public struct ExistsResponse: Sendable, Hashable, Codable {
  public var existence: FileExistence
  public init(existence: FileExistence) { self.existence = existence }
}

public struct LsResponse: Sendable, Hashable, Codable {
  public var entries: [DirectoryEntry]
  public init(entries: [DirectoryEntry]) { self.entries = entries }
}

public struct EnumerateResponse: Sendable, Hashable, Codable {
  public var entries: [EnumeratedEntry]
  public init(entries: [EnumeratedEntry]) { self.entries = entries }
}

public struct MkdirResponse: Sendable, Hashable, Codable {
  public init() {}
}

// FindResult and GrepResult are defined in Runner.swift.

// MARK: - Wire error type

/// Error type used in wire-protocol Result values.
/// Wraps a message string and conforms to Error.
public struct RunnerWireError: Error, Sendable, Hashable, Codable, CustomStringConvertible {
  public var message: String

  public init(_ message: String) { self.message = message }

  public var description: String { message }

  public init(from decoder: any Decoder) throws {
    message = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(message)
  }
}

// MARK: - Unified request/response enums

/// All runner operations.
public enum RunnerOp: String, Sendable, Hashable, Codable {
  case hello
  case bash
  case read
  case write
  case exists
  case ls
  case enumerate
  case mkdir
  case find
  case grep
}

/// A runner request (text frame).
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

  public var requestID: String? {
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
    }
  }

  public var op: RunnerOp {
    switch self {
    case .hello: .hello
    case .bash: .bash
    case .read: .read
    case .write: .write
    case .exists: .exists
    case .ls: .ls
    case .enumerate: .enumerate
    case .mkdir: .mkdir
    case .find: .find
    case .grep: .grep
    }
  }
}

/// A runner response (text frame).
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
    }
  }
}

// MARK: - JSON serialization

/// Envelope keys used in JSON text frames.
private enum EnvelopeKey: String, CodingKey {
  case v, id, op, p, ok, err
}

extension RunnerRequest: Codable {
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: EnvelopeKey.self)
    try c.encode(runnerProtocolVersion, forKey: .v)
    if let id = requestID { try c.encode(id, forKey: .id) }
    try c.encode(op.rawValue, forKey: .op)

    switch self {
    case let .hello(p): try c.encode(p, forKey: .p)
    case let .bash(_, p): try c.encode(p, forKey: .p)
    case let .read(_, p): try c.encode(p, forKey: .p)
    case let .write(_, p): try c.encode(p, forKey: .p)
    case let .exists(_, p): try c.encode(p, forKey: .p)
    case let .ls(_, p): try c.encode(p, forKey: .p)
    case let .enumerate(_, p): try c.encode(p, forKey: .p)
    case let .mkdir(_, p): try c.encode(p, forKey: .p)
    case let .find(_, p): try c.encode(p, forKey: .p)
    case let .grep(_, p): try c.encode(p, forKey: .p)
    }
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: EnvelopeKey.self)
    let op = try c.decode(String.self, forKey: .op)
    let id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""

    switch op {
    case "hello": self = .hello(try c.decode(HelloRequest.self, forKey: .p))
    case "bash": self = .bash(id: id, try c.decode(BashRequest.self, forKey: .p))
    case "read": self = .read(id: id, try c.decode(ReadRequest.self, forKey: .p))
    case "write": self = .write(id: id, try c.decode(WriteRequest.self, forKey: .p))
    case "exists": self = .exists(id: id, try c.decode(ExistsRequest.self, forKey: .p))
    case "ls": self = .ls(id: id, try c.decode(LsRequest.self, forKey: .p))
    case "enumerate": self = .enumerate(id: id, try c.decode(EnumerateRequest.self, forKey: .p))
    case "mkdir": self = .mkdir(id: id, try c.decode(MkdirRequest.self, forKey: .p))
    case "find": self = .find(id: id, try c.decode(FindParams.self, forKey: .p))
    case "grep": self = .grep(id: id, try c.decode(GrepParams.self, forKey: .p))
    default:
      throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "Unknown op: \(op)")
    }
  }
}

extension RunnerResponse: Codable {
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: EnvelopeKey.self)
    try c.encode(runnerProtocolVersion, forKey: .v)

    func encodeResult<T: Encodable>(_ id: String, _ op: RunnerOp, _ result: Result<T, RunnerWireError>) throws {
      try c.encode(id, forKey: .id)
      try c.encode(op.rawValue, forKey: .op)
      switch result {
      case let .success(value): try c.encode(value, forKey: .ok)
      case let .failure(err): try c.encode(err.message, forKey: .err)
      }
    }

    switch self {
    case let .hello(p):
      try c.encode(RunnerOp.hello.rawValue, forKey: .op)
      try c.encode(p, forKey: .ok)
    case let .bash(id, r): try encodeResult(id, .bash, r)
    case let .read(id, r): try encodeResult(id, .read, r)
    case let .write(id, r): try encodeResult(id, .write, r)
    case let .exists(id, r): try encodeResult(id, .exists, r)
    case let .ls(id, r): try encodeResult(id, .ls, r)
    case let .enumerate(id, r): try encodeResult(id, .enumerate, r)
    case let .mkdir(id, r): try encodeResult(id, .mkdir, r)
    case let .find(id, r): try encodeResult(id, .find, r)
    case let .grep(id, r): try encodeResult(id, .grep, r)
    }
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: EnvelopeKey.self)
    let op = try c.decode(String.self, forKey: .op)
    let id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
    let hasError = c.contains(.err)

    func decodeResult<T: Decodable>(_ type: T.Type) throws -> Result<T, RunnerWireError> {
      if hasError {
        let msg = try c.decode(String.self, forKey: .err)
        return .failure(RunnerWireError(msg))
      }
      return .success(try c.decode(T.self, forKey: .ok))
    }

    switch op {
    case "hello": self = .hello(try c.decode(HelloResponse.self, forKey: .ok))
    case "bash": self = .bash(id: id, try decodeResult(BashResult.self))
    case "read": self = .read(id: id, try decodeResult(ReadResponse.self))
    case "write": self = .write(id: id, try decodeResult(WriteResponse.self))
    case "exists": self = .exists(id: id, try decodeResult(ExistsResponse.self))
    case "ls": self = .ls(id: id, try decodeResult(LsResponse.self))
    case "enumerate": self = .enumerate(id: id, try decodeResult(EnumerateResponse.self))
    case "mkdir": self = .mkdir(id: id, try decodeResult(MkdirResponse.self))
    case "find": self = .find(id: id, try decodeResult(FindResult.self))
    case "grep": self = .grep(id: id, try decodeResult(GrepResult.self))
    default:
      throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "Unknown op: \(op)")
    }
  }
}

// MARK: - Binary frame helpers

/// Binary frames carry raw bytes with a length-prefixed ID for correlation.
///
/// Layout: [2 bytes: ID length as UInt16 big-endian][N bytes: ID as UTF-8][M bytes: payload]
///
/// Used for:
/// - `read` response when `binary: true` — runner sends data as binary frame
/// - `write` request when `content` is nil — server sends data as binary frame after the text request
public enum RunnerBinaryFrame {
  /// Encode a binary frame: length-prefixed ID + raw data.
  public static func encode(id: String, data: Data) -> Data {
    let idBytes = Array(id.utf8)
    let len = UInt16(min(idBytes.count, Int(UInt16.max)))
    var frame = Data(capacity: 2 + Int(len) + data.count)
    frame.append(UInt8(len >> 8))
    frame.append(UInt8(len & 0xFF))
    frame.append(contentsOf: idBytes.prefix(Int(len)))
    frame.append(data)
    return frame
  }

  /// Decode a binary frame: extract ID and payload.
  public static func decode(_ frame: Data) -> (id: String, data: Data)? {
    guard frame.count >= 2 else { return nil }
    let len = Int(UInt16(frame[frame.startIndex]) << 8 | UInt16(frame[frame.startIndex + 1]))
    guard frame.count >= 2 + len else { return nil }
    let idData = frame[(frame.startIndex + 2) ..< (frame.startIndex + 2 + len)]
    guard let id = String(data: Data(idData), encoding: .utf8) else { return nil }
    let payload = frame.dropFirst(2 + len)
    return (id: id, data: Data(payload))
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
