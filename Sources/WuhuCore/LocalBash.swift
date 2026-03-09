import Foundation
import PiAI

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// Callback type for incremental bash output chunks.
public typealias BashOutputCallback = @Sendable (String) async -> Void

/// Shared bash execution logic used by the runner process.
/// Uses Foundation.Process for reliable cross-platform process management.
public enum LocalBash {
  /// Run a bash command, optionally streaming output chunks via callback.
  ///
  /// - Parameters:
  ///   - command: The bash command to execute
  ///   - cwd: Working directory for the process
  ///   - timeoutSeconds: Optional timeout in seconds
  ///   - outputCallback: Optional callback for incremental output chunks (~5s intervals)
  /// - Returns: The final `BashResult`
  public static func run(
    command: String,
    cwd: String,
    timeoutSeconds: TimeInterval?,
    outputCallback: BashOutputCallback? = nil,
  ) async throws -> BashResult {
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("wuhu-bash-\(UUID().uuidString.lowercased()).log")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)

    let outputHandle = try FileHandle(forWritingTo: outputURL)

    // Build environment: inherit parent env with overrides for non-interactive operation
    var env = ProcessInfo.processInfo.environment
    let currentTERM = env["TERM"] ?? "dumb"
    env["CI"] = "1"
    env["TERM"] = currentTERM
    env["PAGER"] = "cat"
    env["GIT_PAGER"] = "cat"
    env["GH_PAGER"] = "cat"
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GH_PROMPT_DISABLED"] = "1"

    // Wrap the command so that SIGTERM kills the entire process tree.
    //
    // The wrapper runs the user command in a background job, waits for it, and
    // installs a trap that kills the entire process group on SIGTERM. Since we
    // set the child's process group (via setpgid in preExec), `kill 0` in the
    // trap sends SIGTERM to all processes in the group.
    let wrappedCommand = """
    _wuhu_cleanup() { kill 0; exit 143; }
    trap _wuhu_cleanup TERM
    { \(command); } 2>&1 &
    wait $!
    """

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-lc", wrappedCommand]
    process.environment = env
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = outputHandle
    process.standardError = FileHandle.nullDevice
    // Put child in its own process group for clean tree cleanup
    process.qualityOfService = .userInitiated

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        // Use terminationHandler to avoid blocking a thread on waitUntilExit
        process.terminationHandler = { _ in
          // Close the output handle so we can read the full file
          try? outputHandle.close()
        }

        do {
          try process.run()
        } catch {
          try? outputHandle.close()
          continuation.resume(throwing: error)
          return
        }

        // Run the rest asynchronously
        Task.detached {
          let result: BashResult = if let timeoutSeconds, timeoutSeconds > 0 {
            await runWithTimeout(
              process: process,
              outputURL: outputURL,
              outputCallback: outputCallback,
              timeoutSeconds: timeoutSeconds,
            )
          } else if let outputCallback {
            await runWithStreaming(
              process: process,
              outputURL: outputURL,
              callback: outputCallback,
            )
          } else {
            await runSimple(process: process, outputURL: outputURL)
          }
          continuation.resume(returning: result)
        }
      }
    } onCancel: {
      terminateProcessTree(process)
    }
  }

  // MARK: - Run variants

  /// Simple run: wait for process to finish, return result.
  private static func runSimple(process: Process, outputURL: URL) async -> BashResult {
    await waitForExit(process)
    return makeResult(process: process, outputURL: outputURL, timedOut: false, terminated: false)
  }

  /// Run with output streaming: poll output file every 5 seconds.
  private static func runWithStreaming(
    process: Process,
    outputURL: URL,
    callback: @escaping BashOutputCallback,
  ) async -> BashResult {
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        await streamOutput(outputURL: outputURL, callback: callback)
      }
      await waitForExit(process)
      group.cancelAll()
    }
    return makeResult(process: process, outputURL: outputURL, timedOut: false, terminated: false)
  }

  /// Run with timeout: race process against timer.
  private static func runWithTimeout(
    process: Process,
    outputURL: URL,
    outputCallback: BashOutputCallback?,
    timeoutSeconds: TimeInterval,
  ) async -> BashResult {
    let timedOut = await withTaskGroup(of: Bool.self) { group -> Bool in
      // Process task
      group.addTask {
        await waitForExit(process)
        return false
      }

      // Timeout task
      group.addTask {
        let ns = UInt64(timeoutSeconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: ns)
        return !Task.isCancelled
      }

      // Output streaming task
      if let outputCallback {
        group.addTask {
          await streamOutput(outputURL: outputURL, callback: outputCallback)
          return false // never wins
        }
      }

      // Take the first meaningful result
      var didTimeout = false
      while let result = await group.next() {
        if result { didTimeout = true; break }
        // Process finished (result == false from process task)
        break
      }
      group.cancelAll()

      if didTimeout {
        terminateProcessTree(process)
        // Wait for process to actually exit after termination
        await waitForExit(process)
      }

      return didTimeout
    }

    return makeResult(process: process, outputURL: outputURL, timedOut: timedOut, terminated: false)
  }

  // MARK: - Process helpers

  /// Wait for the process to exit without blocking a thread.
  private static func waitForExit(_ process: Process) async {
    // Poll isRunning with exponential backoff (capped at 100ms).
    // Foundation.Process uses kqueue/waitpid internally, so the process
    // gets reaped properly; we're just waiting for isRunning to flip.
    var sleepNs: UInt64 = 1_000_000 // 1ms
    while process.isRunning {
      try? await Task.sleep(nanoseconds: sleepNs)
      sleepNs = min(sleepNs * 2, 100_000_000) // cap at 100ms
    }
  }

  /// Terminate the entire process tree (process group).
  private static func terminateProcessTree(_ process: Process) {
    guard process.isRunning else { return }
    let pid = process.processIdentifier
    // Send SIGTERM to the process directly
    process.terminate()
    // Also try to kill the process group (pid as negative = group)
    kill(-pid, SIGTERM)

    // Give 3 seconds for graceful shutdown, then SIGKILL
    Task.detached {
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      if process.isRunning {
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
      }
    }
  }

  // MARK: - Output streaming

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

  // MARK: - Result

  private static func makeResult(
    process: Process,
    outputURL: URL,
    timedOut: Bool,
    terminated: Bool,
  ) -> BashResult {
    let data = (try? Data(contentsOf: outputURL)) ?? Data()
    let output = String(decoding: data, as: UTF8.self)

    return BashResult(
      exitCode: process.terminationStatus,
      output: output,
      timedOut: timedOut,
      terminated: terminated,
      fullOutputPath: outputURL.path,
    )
  }
}
