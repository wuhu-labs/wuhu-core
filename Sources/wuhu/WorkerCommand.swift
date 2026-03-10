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
    WuhuDebugLogger.bootstrap()

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

    // 8. Set up orphan deadline tracking
    let deadlineSeconds = orphanDeadline
    let shutdownTracker = OrphanShutdownTracker()

    // Start the initial orphan deadline watcher
    await shutdownTracker.startDeadline(
      seconds: deadlineSeconds, orphanMonitor: orphanMode, buffer: buffer, logger: logger,
      waitForOrphan: true,
    )

    // 9. Accept connections from the runner
    for await connection in listener.connections {
      // Cancel any pending orphan shutdown — a runner has reconnected
      await shutdownTracker.cancelDeadline()

      let runner = runner
      let name = "worker"
      let logger = logger
      let buffer = buffer
      let orphanMonitor = orphanMode
      Task {
        await handleConnection(connection, runner: runner, buffer: buffer, name: name, logger: logger)

        // Connection ended — if we're in orphan mode, restart the deadline
        let isOrphan = await orphanMonitor.isOrphaned()
        if isOrphan {
          await shutdownTracker.startDeadline(
            seconds: deadlineSeconds, orphanMonitor: orphanMonitor, buffer: buffer, logger: logger,
            waitForOrphan: false,
          )
        }
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

    await withTaskGroup(of: Void.self) { group in
      group.addTask { try? await session.run() }
      group.addTask {
        // Pass buffer as callbacks so serve() does NOT call runner.setCallbacks(),
        // keeping the WorkerCallbackBuffer as the permanent callbacks target.
        await MuxRunnerHandler.serve(session: session, runner: runner, name: name, callbacks: buffer)
        logger.info("Runner connection ended")
        await buffer.runnerDisconnected()
      }
      group.addTask {
        // Wait briefly for the mux transport (session.run) and serve() to start
        // before draining pending results. The drain sends callbacks via the
        // MuxCallbackSender which requires the transport to be running and the
        // peer's callback listener to be ready (started after hello exchange).
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        await buffer.runnerConnected(callbackSender)
        logger.info("Runner connected, draining pending results")
      }
    }
  }
}

// MARK: - Orphan shutdown tracker

/// Manages the cancellable orphan shutdown task so reconnection can cancel it.
private actor OrphanShutdownTracker {
  private var task: Task<Void, Never>?

  func cancelDeadline() {
    task?.cancel()
    task = nil
  }

  func startDeadline(
    seconds: Int,
    orphanMonitor: OrphanMonitor,
    buffer: WorkerCallbackBuffer,
    logger: Logger,
    waitForOrphan: Bool,
  ) {
    task?.cancel()
    task = Task {
      if waitForOrphan {
        await orphanMonitor.waitForOrphan()
      }
      logger.info("Runner gone — orphan deadline in \(seconds)s")
      try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
      guard !Task.isCancelled else { return }
      let drained = await buffer.allDrained()
      if drained {
        logger.info("All results drained, exiting")
      } else {
        let remaining = await buffer.pendingCount()
        logger.warning("Orphan deadline reached with \(remaining) pending results, exiting")
      }
      Foundation.exit(0)
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

  func isOrphaned() -> Bool {
    isOrphan
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
