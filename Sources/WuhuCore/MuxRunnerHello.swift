import Foundation
import Mux

/// Protocol version for the mux-based runner protocol.
public let muxRunnerProtocolVersion = 7

/// Performs the hello exchange on a mux session.
///
/// The initiator (whoever opened the transport) opens the first stream
/// and sends a hello. The responder reads it and sends back a hello.
/// Both sides verify protocol version compatibility.
public enum MuxRunnerHello {
  /// Send hello as the runner side. Opens stream 1, writes hello, reads server hello.
  public static func sendAsRunner(session: MuxSession, runnerName: String) async throws -> HelloResponse {
    let stream = try await session.open()
    let hello = HelloResponse(runnerName: runnerName, version: muxRunnerProtocolVersion)
    try await MuxRunnerCodec.writeRequest(stream, op: .hello, payload: hello)
    try await stream.finish()

    let reader = MuxStreamReader(stream: stream)
    let (ok, _, payload) = try await MuxRunnerCodec.readResponse(reader)
    guard ok else {
      let msg = String(decoding: Data(payload), as: UTF8.self)
      throw MuxRunnerRPCError.serverError("Hello rejected: \(msg)")
    }
    return try MuxRunnerCodec.decode(HelloResponse.self, from: payload)
  }

  /// Receive hello from a runner on the first inbound stream.
  /// Returns the runner's hello response after sending our own.
  public static func receiveFromRunner(session: MuxSession, serverName: String) async throws -> HelloResponse {
    var iter = session.inbound.makeAsyncIterator()
    guard let stream = await iter.next() else {
      throw MuxRunnerRPCError.unexpectedEOF
    }

    let reader = MuxStreamReader(stream: stream)
    let (_, payload) = try await MuxRunnerCodec.readRequest(reader)
    let runnerHello = try MuxRunnerCodec.decode(HelloResponse.self, from: payload)

    guard runnerHello.version == muxRunnerProtocolVersion else {
      try await MuxRunnerCodec.writeError(stream, op: .hello, message: "Version mismatch: expected \(muxRunnerProtocolVersion), got \(runnerHello.version)")
      try await stream.finish()
      throw MuxRunnerRPCError.serverError("Runner '\(runnerHello.runnerName)' has protocol version \(runnerHello.version), expected \(muxRunnerProtocolVersion)")
    }

    let serverHello = HelloResponse(runnerName: serverName, version: muxRunnerProtocolVersion)
    try await MuxRunnerCodec.writeSuccess(stream, op: .hello, payload: serverHello)
    try await stream.finish()

    return runnerHello
  }
}
