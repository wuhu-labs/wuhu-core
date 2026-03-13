import Foundation
import Mux

/// Protocol version for the mux runner protocol.
public let muxRunnerProtocolVersion = 11

public enum MuxRunnerHello {
  public static func receiveHello(session: MuxSession, localName: String) async throws -> HelloResponse {
    var iter = session.inbound.makeAsyncIterator()
    guard let stream = await iter.next() else {
      throw MuxRunnerRPCError.unexpectedEOF
    }

    let reader = MuxStreamReader(stream: stream)
    let (_, payload) = try await MuxRunnerCodec.readRequest(reader)
    let peerHello = try MuxRunnerCodec.decode(HelloResponse.self, from: payload)

    guard peerHello.version == muxRunnerProtocolVersion else {
      try await MuxRunnerCodec.writeError(
        stream,
        op: .hello,
        message: "Version mismatch: expected \(muxRunnerProtocolVersion), got \(peerHello.version)",
      )
      try await stream.finish()
      throw MuxRunnerRPCError.serverError(
        "Peer '\(peerHello.runnerName)' has protocol version \(peerHello.version), expected \(muxRunnerProtocolVersion)",
      )
    }

    try await MuxRunnerCodec.writeSuccess(
      stream,
      op: .hello,
      payload: HelloResponse(runnerName: localName, version: muxRunnerProtocolVersion),
    )
    try await stream.finish()
    return peerHello
  }
}
