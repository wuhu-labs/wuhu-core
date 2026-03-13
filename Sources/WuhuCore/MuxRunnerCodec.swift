import Foundation
import Mux

public enum MuxRunnerOp: UInt8, Sendable {
  case hello = 0
  case read = 2
  case write = 3
  case exists = 4
  case ls = 5
  case enumerate = 6
  case mkdir = 7
  case find = 8
  case grep = 9
  case materialize = 10
  case startBash = 11
  case cancelBash = 12
  case bashHeartbeat = 13
  case bashFinished = 14
}

public final class MuxStreamReader {
  private let stream: MuxStream
  private var buffer: [UInt8] = []
  private var iterator: AsyncStream<[UInt8]>.AsyncIterator?
  private var iteratorInitialized = false

  public init(stream: MuxStream) {
    self.stream = stream
  }

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

public enum MuxRunnerCodec {
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

  public static func writeSuccess(_ stream: MuxStream, op: MuxRunnerOp, payload: some Encodable) async throws {
    let json = try JSONEncoder().encode(payload)
    try await writeResponseFrame(stream, op: op, ok: true, payload: Array(json))
  }

  public static func writeError(_ stream: MuxStream, op: MuxRunnerOp, message: String) async throws {
    try await writeResponseFrame(stream, op: op, ok: false, payload: Array(message.utf8))
  }

  public static func writeBinary(_ stream: MuxStream, data: Data) async throws {
    let len = UInt32(data.count)
    var header = [UInt8](repeating: 0, count: 4)
    header[0] = UInt8((len >> 24) & 0xFF)
    header[1] = UInt8((len >> 16) & 0xFF)
    header[2] = UInt8((len >> 8) & 0xFF)
    header[3] = UInt8(len & 0xFF)
    try await stream.write(header + Array(data))
  }

  public static func readRequest(_ reader: MuxStreamReader) async throws -> (MuxRunnerOp, [UInt8]) {
    let header = try await reader.readExact(5)
    guard let op = MuxRunnerOp(rawValue: header[0]) else {
      throw MuxRunnerRPCError.unknownOp(header[0])
    }
    let len = Int(UInt32(header[1]) << 24 | UInt32(header[2]) << 16 | UInt32(header[3]) << 8 | UInt32(header[4]))
    let payload = len > 0 ? try await reader.readExact(len) : []
    return (op, payload)
  }

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

  public static func readBinary(_ reader: MuxStreamReader) async throws -> Data {
    let header = try await reader.readExact(4)
    let len = Int(UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8 | UInt32(header[3]))
    if len == 0 { return Data() }
    return try await Data(reader.readExact(len))
  }

  public static func decode<T: Decodable>(_ type: T.Type, from payload: [UInt8]) throws -> T {
    try JSONDecoder().decode(type, from: Data(payload))
  }

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
