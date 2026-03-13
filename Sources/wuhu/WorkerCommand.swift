import ArgumentParser
import Foundation
import Logging
import Mux
import MuxTCP
import WuhuCore

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

    #if canImport(Glibc)
      let sid = Glibc.setsid()
      if sid == -1 {
        logger.warning("setsid() failed (errno=\(errno)) — may already be session leader")
      } else {
        logger.info("Worker setsid'd, new session \(sid)")
      }
    #endif

    let runner = LocalRunner(id: .local)
    let buffer = WorkerCallbackBuffer(outputDir: outputDir)
    await runner.setCallbacks(buffer)

    await buffer.recoverFromDisk()
    let recoveredCount = await buffer.pendingCount()
    if recoveredCount > 0 {
      logger.info("Recovered \(recoveredCount) pending results from disk")
    }

    logger.info("Worker starting, listening on \(socket)")
    let listener = try await TCPListener.bind(unixDomainSocketPath: socket)

    let orphanMode = OrphanMonitor()
    startLivenessMonitor(orphanMonitor: orphanMode, logger: logger)

    let shutdownTracker = OrphanShutdownTracker()
    await shutdownTracker.startDeadline(
      seconds: orphanDeadline,
      orphanMonitor: orphanMode,
      buffer: buffer,
      logger: logger,
      waitForOrphan: true,
    )

    for await connection in listener.connections {
      await shutdownTracker.cancelDeadline()

      let runner = runner
      let logger = logger
      let buffer = buffer
      let orphanMonitor = orphanMode
      Task {
        await handleConnection(connection, runner: runner, buffer: buffer, logger: logger)
        if await orphanMonitor.isOrphaned() {
          await shutdownTracker.startDeadline(
            seconds: orphanDeadline,
            orphanMonitor: orphanMonitor,
            buffer: buffer,
            logger: logger,
            waitForOrphan: false,
          )
        }
      }
    }
  }

  private func handleConnection(
    _ connection: TCPConnection,
    runner: any Runner,
    buffer: WorkerCallbackBuffer,
    logger: Logger,
  ) async {
    let session = MuxSession(connection: connection, role: .responder)
    let callbackSender = MuxCallbackSender(session: session)
    await buffer.runnerConnected(callbackSender)
    logger.info("Runner connected, draining pending results")

    await withTaskGroup(of: Void.self) { group in
      group.addTask { try? await session.run() }
      group.addTask {
        await MuxRunnerHandler.serve(session: session, runner: runner, name: "worker", callbacks: buffer)
        logger.info("Runner connection ended")
        await buffer.runnerDisconnected()
      }
    }
  }
}

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
      if await buffer.allDrained() {
        logger.info("All results drained, exiting")
      } else {
        let remaining = await buffer.pendingCount()
        logger.warning("Orphan deadline reached with \(remaining) pending results, exiting")
      }
      Foundation.exit(0)
    }
  }
}

private actor OrphanMonitor {
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
