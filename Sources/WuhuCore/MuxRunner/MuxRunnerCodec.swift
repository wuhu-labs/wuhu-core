import Foundation
import Mux

// MARK: - RPC Operation Codes

/// Operation codes for the mux-based runner RPC protocol.
/// Each operation maps to a Runner protocol method.
public enum MuxRunnerOp: UInt8, Sendable {
  case hello = 0
  case bash = 1
  case read = 2
  case write = 3
  case exists = 4
  case ls = 5
  case enumerate = 6
  case mkdir = 7
  case find = 8
  case grep = 9
  case materialize = 10
}

// MARK: - Buffered Stream Reader

/// Wraps a `MuxStream`'s byte sequence with buffering, enabling exact-count reads.
/// Each RPC uses one stream, so this reader is scoped to a single call.
public final class MuxStreamReader {
  private let stream: MuxStream
  private var buffer: [UInt8] = []
  private var iterator: AsyncStream<[UInt8]>.AsyncIterator?
  private var iteratorInitialized = false

  public init(stream: MuxStream) {
    self.stream = stream
  }

  /// Read exactly `count` bytes. Throws on premature EOF.
  public func readExact(_ count: Int) async throws -> [UInt8] {
    if !iteratorInitialized {
      iterator = await stream.bytes.makeAsyncIterator()
      iteratorInitialized = true
    }

    while buffer.count < count {
      guard let chunk = try await iterator?.next() else {
        throw MuxRunnerRPCError.unexpectedEOF
      }
      buffer.append(contentsOf: chunk)
    }
    let result = Array(buffer.prefix(count))
    buffer.removeFirst(count)
    return result
  }

  /// Read all remaining bytes until the stream ends.
  public func readToEnd() async throws -> [UInt8] {
    if !iteratorInitialized {
      iterator = await stream.bytes.makeAsyncIterator()
      iteratorInitialized = true
    }

    var result = buffer
    buffer = []
    while let chunk = try await iterator?.next() {
      result.append(contentsOf: chunk)
    }
    return result
  }
}

// MARK: - Stream Frame Codec

/// Encodes and decodes RPC frames on a mux stream.
///
/// Request frame:
/// ```
/// ┌──────────┬─────────────┬─────────────────────┐
/// │ op (u8)  │ len (u32be) │ payload (JSON bytes) │
/// └──────────┴─────────────┴─────────────────────┘
/// ```
///
/// Response frame:
/// ```
/// ┌──────────┬──────────┬─────────────┬─────────────────────┐
/// │ ok (u8)  │ op (u8)  │ len (u32be) │ payload (JSON bytes) │
/// └──────────┴──────────┴─────────────┴─────────────────────┘
/// ```
///
/// Binary payloads (read/write) are length-prefixed and follow the JSON frame
/// on the same stream.
public enum MuxRunnerCodec {
  // MARK: - Write

  /// Write a request frame to a stream.
  public static func writeRequest(_ stream: MuxStream, op: MuxRunnerOp, payload: some Encodable) async throws {
    let json = try JSONEncoder().encode(payload)
    var frame = [UInt8]()
    frame.reserveCapacity(5 + json.count)
    frame.append(op.rawValue)
    let len = UInt32(json.count)
    frame.append(UInt8((len >> 24) & 0xFF))
    frame.append(UInt8((len >> 16) & 0xFF))
    frame.append(UInt8((len >> 8) & 0xFF))
    frame.append(UInt8(len & 0xFF))
    frame.append(contentsOf: json)
    try await stream.write(frame)
  }

  /// Write a success response with an Encodable payload.
  public static func writeSuccess(_ stream: MuxStream, op: MuxRunnerOp, payload: some Encodable) async throws {
    let json = try JSONEncoder().encode(payload)
    try await writeResponseFrame(stream, op: op, ok: true, payload: Array(json))
  }

  /// Write an error response.
  public static func writeError(_ stream: MuxStream, op: MuxRunnerOp, message: String) async throws {
    let msg = Array(message.utf8)
    try await writeResponseFrame(stream, op: op, ok: false, payload: msg)
  }

  /// Write a length-prefixed binary payload to a stream.
  public static func writeBinary(_ stream: MuxStream, data: Data) async throws {
    let len = UInt32(data.count)
    var header = [UInt8](repeating: 0, count: 4)
    header[0] = UInt8((len >> 24) & 0xFF)
    header[1] = UInt8((len >> 16) & 0xFF)
    header[2] = UInt8((len >> 8) & 0xFF)
    header[3] = UInt8(len & 0xFF)
    try await stream.write(header + Array(data))
  }

  // MARK: - Read

  /// Read a request frame. Returns (op, JSON payload bytes).
  public static func readRequest(_ reader: MuxStreamReader) async throws -> (MuxRunnerOp, [UInt8]) {
    let header = try await reader.readExact(5)
    guard let op = MuxRunnerOp(rawValue: header[0]) else {
      throw MuxRunnerRPCError.unknownOp(header[0])
    }
    let len = Int(UInt32(header[1]) << 24 | UInt32(header[2]) << 16 | UInt32(header[3]) << 8 | UInt32(header[4]))
    let payload = len > 0 ? try await reader.readExact(len) : []
    return (op, payload)
  }

  /// Read a response frame. Returns (ok, op, JSON payload bytes).
  public static func readResponse(_ reader: MuxStreamReader) async throws -> (ok: Bool, op: MuxRunnerOp, payload: [UInt8]) {
    let header = try await reader.readExact(6)
    let ok = header[0] != 0
    guard let op = MuxRunnerOp(rawValue: header[1]) else {
      throw MuxRunnerRPCError.unknownOp(header[1])
    }
    let len = Int(UInt32(header[2]) << 24 | UInt32(header[3]) << 16 | UInt32(header[4]) << 8 | UInt32(header[5]))
    let payload = len > 0 ? try await reader.readExact(len) : []
    return (ok, op, payload)
  }

  /// Read a length-prefixed binary payload.
  public static func readBinary(_ reader: MuxStreamReader) async throws -> Data {
    let header = try await reader.readExact(4)
    let len = Int(UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8 | UInt32(header[3]))
    if len == 0 { return Data() }
    let bytes = try await reader.readExact(len)
    return Data(bytes)
  }

  /// Decode JSON payload bytes into a Decodable type.
  public static func decode<T: Decodable>(_ type: T.Type, from payload: [UInt8]) throws -> T {
    try JSONDecoder().decode(type, from: Data(payload))
  }

  // MARK: - Internal

  private static func writeResponseFrame(_ stream: MuxStream, op: MuxRunnerOp, ok: Bool, payload: [UInt8]) async throws {
    var frame = [UInt8]()
    frame.reserveCapacity(6 + payload.count)
    frame.append(ok ? 1 : 0)
    frame.append(op.rawValue)
    let len = UInt32(payload.count)
    frame.append(UInt8((len >> 24) & 0xFF))
    frame.append(UInt8((len >> 16) & 0xFF))
    frame.append(UInt8((len >> 8) & 0xFF))
    frame.append(UInt8(len & 0xFF))
    frame.append(contentsOf: payload)
    try await stream.write(frame)
  }
}

// MARK: - Errors

public enum MuxRunnerRPCError: Error, Sendable, CustomStringConvertible {
  case unknownOp(UInt8)
  case unexpectedEOF
  case serverError(String)
  case unexpectedResponse

  public var description: String {
    switch self {
    case let .unknownOp(op): "Unknown RPC op: \(op)"
    case .unexpectedEOF: "Unexpected end of stream"
    case let .serverError(msg): "Runner error: \(msg)"
    case .unexpectedResponse: "Unexpected response format"
    }
  }
}
