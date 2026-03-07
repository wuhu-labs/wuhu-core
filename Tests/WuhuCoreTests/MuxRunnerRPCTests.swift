import Foundation
import Mux
import Testing

@testable import WuhuCore

@Suite("Mux Runner RPC")
struct MuxRunnerRPCTests {

  /// Helper: create an in-memory mux session pair, run both, and execute body.
  private func withMuxPair(
    body: (MuxSession, MuxSession) async throws -> Void
  ) async throws {
    let (connA, connB) = InMemoryConnection.makePair()
    let client = MuxSession(connection: connA, role: .initiator, config: MuxConfig(keepaliveInterval: nil))
    let server = MuxSession(connection: connB, role: .responder, config: MuxConfig(keepaliveInterval: nil))
    let taskA = Task { try await client.run() }
    let taskB = Task { try await server.run() }
    defer {
      taskA.cancel()
      taskB.cancel()
    }
    try await body(client, server)
    await client.close()
    await server.close()
  }

  @Test("Codec round-trip: request frame encode/decode")
  func codecRoundTrip() async throws {
    try await withMuxPair { clientSession, serverSession in
      let stream = try await clientSession.open()

      // Write a request
      let req = BashRequest(command: "echo hello", cwd: "/tmp", timeout: nil)
      try await MuxRunnerCodec.writeRequest(stream, op: .bash, payload: req)
      try await stream.finish()

      // Read on server side
      var iter = serverSession.inbound.makeAsyncIterator()
      let inbound = await iter.next()!
      let reader = MuxStreamReader(stream: inbound)
      let (op, payload) = try await MuxRunnerCodec.readRequest(reader)

      #expect(op == .bash)
      let decoded = try MuxRunnerCodec.decode(BashRequest.self, from: payload)
      #expect(decoded.command == "echo hello")
      #expect(decoded.cwd == "/tmp")
    }
  }

  @Test("Full RPC round-trip: MuxRunnerClient -> MuxRunnerHandler -> LocalRunner")
  func fullRPCRoundTrip() async throws {
    try await withMuxPair { clientSession, serverSession in
      let runner = LocalRunner()

      // Start handler on server side
      let handlerTask = Task {
        await MuxRunnerHandler.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      // Create client
      let client = MuxRunnerClient(name: "test-runner", session: clientSession)

      // Test exists
      let existence = try await client.exists(path: "/tmp")
      #expect(existence == .directory)

      // Test exists (non-existent)
      let noFile = try await client.exists(path: "/tmp/definitely-does-not-exist-\(UUID().uuidString)")
      #expect(noFile == .notFound)

      // Test mkdir + write + read string
      let testDir = "/tmp/wuhu-mux-test-\(UUID().uuidString)"
      try await client.createDirectory(path: testDir, withIntermediateDirectories: true)
      let testFile = "\(testDir)/hello.txt"
      try await client.writeString(path: testFile, content: "hello mux!", createIntermediateDirectories: false, encoding: .utf8)
      let content = try await client.readString(path: testFile, encoding: .utf8)
      #expect(content == "hello mux!")

      // Test binary write + read
      let binaryFile = "\(testDir)/data.bin"
      let testData = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x42])
      try await client.writeData(path: binaryFile, data: testData, createIntermediateDirectories: false)
      let readData = try await client.readData(path: binaryFile)
      #expect(readData == testData)

      // Test ls
      let entries = try await client.listDirectory(path: testDir)
      let names = entries.map(\.name).sorted()
      #expect(names == ["data.bin", "hello.txt"])

      // Test bash
      let result = try await client.runBash(command: "echo 'mux works'", cwd: "/tmp", timeout: 10)
      #expect(result.output.contains("mux works"))
      #expect(result.exitCode == 0)

      // Cleanup
      try? await client.runBash(command: "rm -rf \(testDir)", cwd: "/tmp", timeout: 5)
    }
  }

  @Test("Multiple concurrent RPCs on the same session")
  func concurrentRPCs() async throws {
    try await withMuxPair { clientSession, serverSession in
      let runner = LocalRunner()
      let handlerTask = Task {
        await MuxRunnerHandler.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let client = MuxRunnerClient(name: "test-runner", session: clientSession)

      // Fire 10 concurrent exists checks
      try await withThrowingTaskGroup(of: FileExistence.self) { group in
        for _ in 0 ..< 10 {
          group.addTask {
            try await client.exists(path: "/tmp")
          }
        }
        var results: [FileExistence] = []
        for try await result in group {
          results.append(result)
        }
        #expect(results.count == 10)
        #expect(results.allSatisfy { $0 == .directory })
      }
    }
  }
}
