import Foundation
import Logging
import PiAI
import Subprocess

#if canImport(System)
  @preconcurrency import System
#else
  @preconcurrency import SystemPackage
#endif

private let logger = WuhuDebugLogger.logger("LocalBash")

/// Callback type for incremental bash output chunks.
public typealias BashOutputCallback = @Sendable (String) async -> Void

/// Shared bash execution logic used by the runner process.
/// Uses swift-subprocess for reliable process management:
/// - Process groups for clean tree cleanup (`processGroupID = 0`)
/// - pidfd/kqueue-based exit monitoring (no polling)
/// - Structured teardown sequences on cancellation
public enum LocalBash {
  /// Run a bash command, optionally streaming output chunks via callback.
  ///
  /// - Parameters:
  ///   - command: The bash command to execute
  ///   - cwd: Working directory for the process
  ///   - timeoutSeconds: Optional timeout in seconds
  ///   - tag: Optional tag for log correlation (from tool call ID)
  ///   - outputCallback: Optional callback for incremental output chunks (~5s intervals)
  /// - Returns: The final `BashResult`
  public static func run(
    command: String,
    cwd: String,
    timeoutSeconds: TimeInterval?,
    tag: String? = nil,
    outputCallback: BashOutputCallback? = nil,
  ) async throws -> BashResult {
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("wuhu-bash-\(UUID().uuidString.lowercased()).log")
    _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)

    let outputFD = try FileDescriptor.open(
      FilePath(outputURL.path),
      .writeOnly,
      options: [.create, .truncate],
      permissions: [.ownerReadWrite, .groupRead, .otherRead],
    )

    var _platformOptions = PlatformOptions()
    // Put child in its own process group so we can kill the entire tree
    _platformOptions.processGroupID = 0
    // Structured teardown on task cancellation: SIGTERM → 3s → SIGKILL
    _platformOptions.teardownSequence = [
      .send(signal: .terminate, allowedDurationToNextStep: .seconds(3)),
    ]
    let platformOptions = _platformOptions

    // Build environment: inherit parent env with overrides for non-interactive operation
    let currentTERM = ProcessInfo.processInfo.environment["TERM"] ?? "dumb"
    let env: Environment = .inherit.updating([
      "CI": "1",
      "TERM": currentTERM,
      "PAGER": "cat",
      "GIT_PAGER": "cat",
      "GH_PAGER": "cat",
      "GIT_TERMINAL_PROMPT": "0",
      "GH_PROMPT_DISABLED": "1",
    ])

    // Wrap the command so that SIGTERM kills the entire process tree.
    //
    // swift-subprocess's teardownSequence sends SIGTERM to the bash process only
    // (toProcessGroup: false), so child processes like `sleep` survive as orphans.
    //
    // The wrapper runs the user command in a background job, waits for it, and
    // installs a trap that kills the entire process group on SIGTERM. Since the
    // child uses processGroupID=0 (PGID == PID), `kill 0` in the trap sends
    // SIGTERM to all processes in the group.
    let wrappedCommand = """
    _wuhu_cleanup() { kill 0; exit 143; }
    trap _wuhu_cleanup TERM
    { \(command); } 2>&1 &
    wait $!
    """

    let commandPreview = String(command.prefix(50))
    let tagForLog = tag ?? "none"

    // When there's a timeout, we race the subprocess against a timer.
    // When the parent task is cancelled, the teardownSequence handles cleanup.
    if let timeoutSeconds, timeoutSeconds > 0 {
      return try await withThrowingTaskGroup(of: BashRunOutcome.self, returning: BashResult.self) { group in
        // Task 1: Run the subprocess with closure to get PID immediately
        group.addTask {
          let result = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: ["-lc", wrappedCommand],
            environment: env,
            workingDirectory: FilePath(cwd),
            platformOptions: platformOptions,
            input: .none,
            output: .fileDescriptor(outputFD, closeAfterSpawningProcess: true),
            error: .discarded,
          ) { execution -> Int32 in
            let pid = execution.processIdentifier.value
            logger.debug(
              "process started",
              metadata: [
                "tag": "\(tagForLog)",
                "pid": "\(pid)",
                "cwd": "\(cwd)",
                "timeout": "\(timeoutSeconds)",
                "commandPreview": "\(commandPreview)",
              ],
            )
            // Return PID from closure so we can access it after completion
            return pid
          }

          let pid = result.value
          let exitCode: Int32 = switch result.terminationStatus {
          case let .exited(code): code
          case let .unhandledException(sig): -sig
          }

          logger.debug(
            "process exited",
            metadata: [
              "tag": "\(tagForLog)",
              "pid": "\(pid)",
              "exitCode": "\(exitCode)",
            ],
          )

          return .completed(result.terminationStatus, pid: pid)
        }

        // Task 2: Timeout timer
        group.addTask {
          let ns = UInt64(timeoutSeconds * 1_000_000_000)
          try await Task.sleep(nanoseconds: ns)
          return .timedOut
        }

        // Task 3: Output streaming (if callback provided)
        if let outputCallback {
          group.addTask {
            await streamOutput(outputURL: outputURL, callback: outputCallback)
            return .outputStreamDone
          }
        }

        // Take the first subprocess/timeout result
        var first: BashRunOutcome?
        while let result = try await group.next() {
          if case .outputStreamDone = result { continue }
          first = result
          break
        }
        // Cancel remaining tasks (timer, output stream)
        group.cancelAll()

        switch first ?? .timedOut {
        case let .completed(status, _):
          return makeResult(terminationStatus: status, outputURL: outputURL, timedOut: false, terminated: false)
        case .timedOut:
          logger.debug(
            "process timed out",
            metadata: [
              "tag": "\(tagForLog)",
              "timeout": "\(timeoutSeconds)",
            ],
          )
          // The subprocess task gets cancelled → teardownSequence runs
          // Wait for the subprocess task to finish cleanup
          _ = try? await group.next()
          return makeResult(terminationStatus: .exited(-1), outputURL: outputURL, timedOut: true, terminated: false)
        case .outputStreamDone:
          // Should not happen — outputStreamDone is filtered in the while loop.
          // Treat as if subprocess didn't finish.
          _ = try? await group.next()
          return makeResult(terminationStatus: .exited(-1), outputURL: outputURL, timedOut: false, terminated: false)
        }
      }
    } else if let outputCallback {
      // No timeout but with output streaming: use a task group.
      return try await withThrowingTaskGroup(of: BashRunOutcome.self, returning: BashResult.self) { group in
        group.addTask {
          let result = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: ["-lc", wrappedCommand],
            environment: env,
            workingDirectory: FilePath(cwd),
            platformOptions: platformOptions,
            input: .none,
            output: .fileDescriptor(outputFD, closeAfterSpawningProcess: true),
            error: .discarded,
          ) { execution -> Int32 in
            let pid = execution.processIdentifier.value
            logger.debug(
              "process started",
              metadata: [
                "tag": "\(tagForLog)",
                "pid": "\(pid)",
                "cwd": "\(cwd)",
                "commandPreview": "\(commandPreview)",
              ],
            )
            return pid
          }

          let pid = result.value
          let exitCode: Int32 = switch result.terminationStatus {
          case let .exited(code): code
          case let .unhandledException(sig): -sig
          }

          logger.debug(
            "process exited",
            metadata: [
              "tag": "\(tagForLog)",
              "pid": "\(pid)",
              "exitCode": "\(exitCode)",
            ],
          )

          return .completed(result.terminationStatus, pid: pid)
        }

        group.addTask {
          await streamOutput(outputURL: outputURL, callback: outputCallback)
          return .outputStreamDone
        }

        var status: TerminationStatus?
        while let result = try await group.next() {
          if case let .completed(s, _) = result {
            status = s
            break
          }
        }
        group.cancelAll()

        return makeResult(
          terminationStatus: status ?? .exited(-1),
          outputURL: outputURL,
          timedOut: false,
          terminated: false,
        )
      }
    } else {
      // No timeout: simple run with closure to log PID at start.
      let result = try await Subprocess.run(
        .path("/bin/bash"),
        arguments: ["-lc", wrappedCommand],
        environment: env,
        workingDirectory: FilePath(cwd),
        platformOptions: platformOptions,
        input: .none,
        output: .fileDescriptor(outputFD, closeAfterSpawningProcess: true),
        error: .discarded,
      ) { execution -> Int32 in
        let pid = execution.processIdentifier.value
        logger.debug(
          "process started",
          metadata: [
            "tag": "\(tagForLog)",
            "pid": "\(pid)",
            "cwd": "\(cwd)",
            "commandPreview": "\(commandPreview)",
          ],
        )
        return pid
      }

      let pid = result.value
      let exitCode: Int32 = switch result.terminationStatus {
      case let .exited(code): code
      case let .unhandledException(sig): -sig
      }

      logger.debug(
        "process exited",
        metadata: [
          "tag": "\(tagForLog)",
          "pid": "\(pid)",
          "exitCode": "\(exitCode)",
        ],
      )

      return makeResult(
        terminationStatus: result.terminationStatus,
        outputURL: outputURL,
        timedOut: false,
        terminated: false,
      )
    }
  }

  // MARK: - Private

  private enum BashRunOutcome: Sendable {
    case completed(TerminationStatus, pid: Int32)
    case timedOut
    case outputStreamDone
  }

  /// Periodically read new output from the file and send it via callback.
  private static func streamOutput(outputURL: URL, callback: BashOutputCallback) async {
    var bytesRead = 0
    while !Task.isCancelled {
      try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
      if Task.isCancelled { break }
      guard let data = try? Data(contentsOf: outputURL) else { continue }
      if data.count > bytesRead {
        let newData = data[bytesRead...]
        let chunk = String(decoding: newData, as: UTF8.self)
        if !chunk.isEmpty {
          await callback(chunk)
        }
        bytesRead = data.count
      }
    }
  }

  private static func makeResult(
    terminationStatus: TerminationStatus,
    outputURL: URL,
    timedOut: Bool,
    terminated: Bool,
  ) -> BashResult {
    let data = (try? Data(contentsOf: outputURL)) ?? Data()
    let output = String(decoding: data, as: UTF8.self)

    let exitCode: Int32 = switch terminationStatus {
    case let .exited(code): code
    case let .unhandledException(sig): -sig
    }

    return BashResult(
      exitCode: exitCode,
      output: output,
      timedOut: timedOut,
      terminated: terminated,
      fullOutputPath: outputURL.path,
    )
  }
}
