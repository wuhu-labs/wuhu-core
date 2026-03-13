import Foundation
import Mux
import MuxTCP
import WuhuCore

public struct MuxWorkerConnector: WorkerConnector {
  public init() {}

  public func connect(socketPath: String) async throws -> any WorkerConnectionHandle {
    let connection = try await TCPConnector.connect(unixDomainSocketPath: socketPath)
    let session = MuxSession(connection: connection, role: .initiator)
    let sessionTask = Task { try await session.run() }

    let helloStream = try await session.open()
    try await MuxRunnerCodec.writeRequest(
      helloStream,
      op: .hello,
      payload: HelloResponse(runnerName: "worker-manager", version: muxRunnerProtocolVersion),
    )
    try await helloStream.finish()

    let reader = MuxStreamReader(stream: helloStream)
    let (ok, _, payload) = try await MuxRunnerCodec.readResponse(reader)
    guard ok else {
      await session.close()
      sessionTask.cancel()
      throw WorkerConnectorError.helloFailed(String(decoding: Data(payload), as: UTF8.self))
    }

    let peerHello = try MuxRunnerCodec.decode(HelloResponse.self, from: payload)
    guard peerHello.version == muxRunnerProtocolVersion else {
      await session.close()
      sessionTask.cancel()
      throw WorkerConnectorError.versionMismatch(peerHello.version)
    }

    let client = MuxRunnerClient(name: peerHello.runnerName, session: session)
    return MuxWorkerConnectionHandle(client: client, session: session, sessionTask: sessionTask)
  }
}

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
    case let .helloFailed(message):
      "Worker hello failed: \(message)"
    case let .versionMismatch(version):
      "Worker protocol version mismatch: \(version)"
    }
  }
}
