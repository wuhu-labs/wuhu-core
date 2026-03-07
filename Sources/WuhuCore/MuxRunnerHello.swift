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
  /// Receive hello from the remote peer on the first inbound stream.
  /// Verifies protocol version, sends our own hello back, and returns the peer's hello.
  public static func receiveHello(session: MuxSession, localName: String) async throws -> HelloResponse {
    var iter = session.inbound.makeAsyncIterator()
    guard let stream = await iter.next() else {
      throw MuxRunnerRPCError.unexpectedEOF
    }

    let reader = MuxStreamReader(stream: stream)
    let (_, payload) = try await MuxRunnerCodec.readRequest(reader)
    let peerHello = try MuxRunnerCodec.decode(HelloResponse.self, from: payload)

    guard peerHello.version == muxRunnerProtocolVersion else {
      try await MuxRunnerCodec.writeError(stream, op: .hello, message: "Version mismatch: expected \(muxRunnerProtocolVersion), got \(peerHello.version)")
      try await stream.finish()
      throw MuxRunnerRPCError.serverError("Peer '\(peerHello.runnerName)' has protocol version \(peerHello.version), expected \(muxRunnerProtocolVersion)")
    }

    let localHello = HelloResponse(runnerName: localName, version: muxRunnerProtocolVersion)
    try await MuxRunnerCodec.writeSuccess(stream, op: .hello, payload: localHello)
    try await stream.finish()

    return peerHello
  }
}
