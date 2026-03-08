import Foundation
import PiAI
import Subprocess

#if canImport(System)
  @preconcurrency import System
#else
  @preconcurrency import SystemPackage
#endif

/// Shared bash execution logic used by the runner process.
/// Uses swift-subprocess for reliable process management:
/// - Process groups for clean tree cleanup (`processGroupID = 0`)
/// - pidfd/kqueue-based exit monitoring (no polling)
/// - Structured teardown sequences on cancellation
public enum LocalBash {
  /// Output chunk callback type.
  public typealias OutputChunkCallback = @Sendable (String) async -> Void

  /// Interval between output chunk pushes (seconds).
  private static let chunkInterval: UInt64 = 10_000_000_000 // 10s

  public static func run(
    command: String,
    cwd: String,
    timeoutSeconds: TimeInterval?,
    onOutputChunk: OutputChunkCallback? = nil,
  ) async throws -> BashResult {
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("wuhu-bash-\(UUID().uuidString.lowercased()).log")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)

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
    let wrappedCommand = """
    _wuhu_cleanup() { kill 0; exit 143; }
    trap _wuhu_cleanup TERM
    { \(command); } &
    wait $!
    """

    // When there's a timeout, we race the subprocess against a timer.
    // When the parent task is cancelled, the teardownSequence handles cleanup.
    if let timeoutSeconds, timeoutSeconds > 0 {
      return try await withThrowingTaskGroup(of: BashRunOutcome.self, returning: BashResult.self) { group in
        // Task 1: Run the subprocess
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
          )
          return .completed(result.terminationStatus)
        }

        // Task 2: Timeout timer
        group.addTask {
          let ns = UInt64(timeoutSeconds * 1_000_000_000)
          try await Task.sleep(nanoseconds: ns)
          return .timedOut
        }

        // Task 3: Output chunk monitor (if callback provided)
        if let onOutputChunk {
          group.addTask {
            await monitorOutput(outputURL: outputURL, callback: onOutputChunk)
            return .chunkMonitorDone
          }
        }

        // Take the first non-monitor result
        var first: BashRunOutcome?
        while let outcome = try await group.next() {
          if case .chunkMonitorDone = outcome { continue }
          first = outcome
          break
        }
        // Cancel remaining tasks
        group.cancelAll()

        switch first {
        case let .completed(status):
          return makeResult(terminationStatus: status, outputURL: outputURL, timedOut: false, terminated: false)
        case .timedOut:
          // Wait for the subprocess task to finish cleanup
          for try await outcome in group {
            if case .completed = outcome { break }
          }
          return makeResult(terminationStatus: .exited(-1), outputURL: outputURL, timedOut: true, terminated: false)
        default:
          return makeResult(terminationStatus: .exited(-1), outputURL: outputURL, timedOut: false, terminated: false)
        }
      }
    } else {
      // No timeout: simple collected run with optional chunk monitoring.
      if let onOutputChunk {
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
            )
            return .completed(result.terminationStatus)
          }

          group.addTask {
            await monitorOutput(outputURL: outputURL, callback: onOutputChunk)
            return .chunkMonitorDone
          }

          var status: TerminationStatus = .exited(-1)
          for try await outcome in group {
            if case let .completed(s) = outcome {
              status = s
              group.cancelAll()
              break
            }
          }

          return makeResult(
            terminationStatus: status,
            outputURL: outputURL,
            timedOut: false,
            terminated: false,
          )
        }
      } else {
        // No timeout, no chunks: simple run.
        let result = try await Subprocess.run(
          .path("/bin/bash"),
          arguments: ["-lc", wrappedCommand],
          environment: env,
          workingDirectory: FilePath(cwd),
          platformOptions: platformOptions,
          input: .none,
          output: .fileDescriptor(outputFD, closeAfterSpawningProcess: true),
          error: .discarded,
        )
        return makeResult(
          terminationStatus: result.terminationStatus,
          outputURL: outputURL,
          timedOut: false,
          terminated: false,
        )
      }
    }
  }

  // MARK: - Private

  private enum BashRunOutcome: Sendable {
    case completed(TerminationStatus)
    case timedOut
    case chunkMonitorDone
  }

  /// Monitor the output file and push chunks periodically.
  private static func monitorOutput(outputURL: URL, callback: @escaping OutputChunkCallback) async {
    var bytesRead = 0

    while !Task.isCancelled {
      do {
        try await Task.sleep(nanoseconds: chunkInterval)
      } catch {
        break
      }

      guard let data = try? Data(contentsOf: outputURL) else { continue }
      let currentSize = data.count
      if currentSize > bytesRead {
        let newData = data[bytesRead ..< currentSize]
        let chunk = String(decoding: newData, as: UTF8.self)
        if !chunk.isEmpty {
          await callback(chunk)
        }
        bytesRead = currentSize
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
