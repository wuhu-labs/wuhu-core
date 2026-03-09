import Foundation
import Mux
import MuxSocket
import WuhuCore

/// Real ``WorkerConnector`` implementation using UDS mux connections.
///
/// Connects to a worker's Unix domain socket, performs a hello exchange,
/// and returns a ``WorkerConnectionHandle`` wrapping a ``MuxRunnerClient``.
public struct MuxWorkerConnector: WorkerConnector {
  public init() {}

  public func connect(socketPath: String) async throws -> any WorkerConnectionHandle {
    let connection = try await SocketConnector.connect(unixDomainSocketPath: socketPath)
    let session = MuxSession(connection: connection, role: .initiator)
    let sessionTask = Task { try await session.run() }

    // Hello exchange
    let helloStream = try await session.open()
    let hello = HelloResponse(runnerName: "worker-manager", version: muxRunnerProtocolVersion)
    try await MuxRunnerCodec.writeRequest(helloStream, op: .hello, payload: hello)
    try await helloStream.finish()

    let reader = MuxStreamReader(stream: helloStream)
    let (ok, _, payload) = try await MuxRunnerCodec.readResponse(reader)
    guard ok else {
      let msg = String(decoding: Data(payload), as: UTF8.self)
      await session.close()
      sessionTask.cancel()
      throw WorkerConnectorError.helloFailed(msg)
    }

    let peerHello = try MuxRunnerCodec.decode(HelloResponse.self, from: payload)
    guard peerHello.version == muxRunnerProtocolVersion else {
      await session.close()
      sessionTask.cancel()
      throw WorkerConnectorError.versionMismatch(peerHello.version)
    }

    let client = MuxRunnerClient(name: peerHello.runnerName, session: session)
    return MuxWorkerConnectionHandle(
      client: client,
      session: session,
      sessionTask: sessionTask,
    )
  }
}

/// Connection handle wrapping a real ``MuxRunnerClient`` and mux session.
final class MuxWorkerConnectionHandle: WorkerConnectionHandle, @unchecked Sendable {
  let runner: any Runner
  private let client: MuxRunnerClient
  private let session: MuxSession
  private let sessionTask: Task<Void, any Error>

  init(client: MuxRunnerClient, session: MuxSession, sessionTask: Task<Void, any Error>) {
    self.client = client
    runner = client
    self.session = session
    self.sessionTask = sessionTask
  }

  func startCallbackListener() async {
    await client.startCallbackListener()
  }

  func close() async {
    await session.close()
    sessionTask.cancel()
  }
}

enum WorkerConnectorError: Error, CustomStringConvertible {
  case helloFailed(String)
  case versionMismatch(Int)

  var description: String {
    switch self {
    case let .helloFailed(msg):
      "Worker hello failed: \(msg)"
    case let .versionMismatch(v):
      "Worker protocol version mismatch: \(v)"
    }
  }
}
