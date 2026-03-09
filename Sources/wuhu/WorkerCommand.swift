import ArgumentParser
import Foundation
import Logging
import Mux
import MuxSocket
import WuhuCore
import WuhuRunner

#if canImport(Glibc)
  import Glibc
#endif

struct WorkerCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "worker",
    abstract: "Run a Wuhu worker process (managed by a runner).",
  )

  @Option(help: "Path to the UDS socket to listen on.")
  var socket: String

  @Option(help: "Path to the output directory for buffered results.")
  var outputDir: String

  @Option(help: "Seconds to wait for a runner to reconnect before exiting (default: 3600).")
  var orphanDeadline: Int = 3600

  func run() async throws {
    let logger = Logger(label: "WuhuWorker")

    // 1. Detach from the runner's session
    #if canImport(Glibc)
      let sid = Glibc.setsid()
      if sid == -1 {
        logger.warning("setsid() failed (errno=\(errno)) — may already be session leader")
      } else {
        logger.info("Worker setsid'd, new session \(sid)")
      }
    #endif

    // 2. Create the LocalRunner
    let runner = LocalRunner()

    // 3. Create the WorkerCallbackBuffer backed by the output directory
    let buffer = WorkerCallbackBuffer(outputDir: outputDir)

    // 4. Set the buffer as the LocalRunner's callbacks target
    await runner.setCallbacks(buffer)

    // 5. Recover any persisted results from a previous crash
    await buffer.recoverFromDisk()
    let recoveredCount = await buffer.pendingCount()
    if recoveredCount > 0 {
      logger.info("Recovered \(recoveredCount) pending results from disk")
    }

    // 6. Start the UDS mux listener
    logger.info("Worker starting, listening on \(socket)")
    let listener = try await SocketListener.bind(unixDomainSocketPath: socket)

    // 7. Start the liveness pipe monitor (stdin EOF = runner gone)
    let orphanMode = OrphanMonitor()
    startLivenessMonitor(orphanMonitor: orphanMode, logger: logger)

    // 8. Start orphan deadline watcher
    let deadlineSeconds = orphanDeadline
    Task {
      await orphanMode.waitForOrphan()
      logger.info("Runner gone — orphan deadline in \(deadlineSeconds)s")
      try? await Task.sleep(nanoseconds: UInt64(deadlineSeconds) * 1_000_000_000)
      let drained = await buffer.allDrained()
      if drained {
        logger.info("All results drained, exiting")
      } else {
        let remaining = await buffer.pendingCount()
        logger.warning("Orphan deadline reached with \(remaining) pending results, exiting")
      }
      Foundation.exit(0)
    }

    // 9. Accept connections from the runner
    for await connection in listener.connections {
      let runner = runner
      let name = "worker"
      let logger = logger
      let buffer = buffer
      Task {
        await handleConnection(connection, runner: runner, buffer: buffer, name: name, logger: logger)
      }
    }
  }

  private func handleConnection(
    _ connection: SocketConnection,
    runner: any Runner,
    buffer: WorkerCallbackBuffer,
    name: String,
    logger: Logger,
  ) async {
    let session = MuxSession(connection: connection, role: .responder)

    // Create a callback sender for this connection so results flow back to the runner
    let callbackSender = MuxCallbackSender(session: session)
    await buffer.runnerConnected(callbackSender)
    logger.info("Runner connected, draining pending results")

    await withTaskGroup(of: Void.self) { group in
      group.addTask { try? await session.run() }
      group.addTask {
        await MuxRunnerHandler.serve(session: session, runner: runner, name: name)
        logger.info("Runner connection ended")
        await buffer.runnerDisconnected()
      }
    }
  }
}

// MARK: - Liveness monitor

/// Tracks whether the runner (parent) is still alive.
actor OrphanMonitor {
  private var isOrphan = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func markOrphan() {
    isOrphan = true
    for waiter in waiters {
      waiter.resume()
    }
    waiters.removeAll()
  }

  func waitForOrphan() async {
    if isOrphan { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

private func startLivenessMonitor(orphanMonitor: OrphanMonitor, logger: Logger) {
  Task.detached {
    let stdin = FileHandle.standardInput
    while true {
      let data = stdin.availableData
      if data.isEmpty {
        logger.info("Liveness pipe EOF — runner is gone, entering orphan mode")
        await orphanMonitor.markOrphan()
        return
      }
    }
  }
}
