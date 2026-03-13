import Foundation
import PiAI

/// Shared bash execution logic used by `LocalRunner` and tool implementations.
/// Extracted to avoid duplication between runner and tool layers.
public enum LocalBash {
  public static func run(command: String, cwd: String, timeoutSeconds: TimeInterval?) async throws -> BashResult {
    #if os(macOS) || os(Linux)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/bash")
      process.arguments = ["-lc", command]
      process.currentDirectoryURL = URL(fileURLWithPath: cwd)
      process.standardInput = FileHandle.nullDevice

      // Run tools in a non-interactive environment. Some CLIs (notably `gh`) will attempt to prompt
      // via the controlling TTY, which can hang an agent loop indefinitely.
      var env = ProcessInfo.processInfo.environment
      env["CI"] = "1"
      env["TERM"] = env["TERM"]?.nilIfEmpty() ?? "dumb"
      env["PAGER"] = "cat"
      env["GIT_PAGER"] = "cat"
      env["GH_PAGER"] = "cat"
      env["GIT_TERMINAL_PROMPT"] = "0"
      env["GH_PROMPT_DISABLED"] = "1"
      process.environment = env

      let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("wuhu-bash-\(UUID().uuidString.lowercased()).log")
      _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
      let outputHandle = try FileHandle(forWritingTo: outputURL)
      process.standardOutput = outputHandle
      process.standardError = outputHandle

      try process.run()
      let pid = process.processIdentifier

      let start = Date()
      var timedOut = false
      var terminated = false
      do {
        while process.isRunning {
          if Task.isCancelled {
            terminated = true
            process.terminate()
            break
          }
          if let timeoutSeconds, timeoutSeconds > 0, Date().timeIntervalSince(start) > timeoutSeconds {
            timedOut = true
            process.terminate()
            break
          }
          try await Task.sleep(nanoseconds: 50_000_000)

          // Fallback: Foundation's Process.isRunning relies on a dispatch source
          // that can miss fast exits in rare cases. If the process no longer exists
          // at the OS level, break out instead of polling forever.
          if process.isRunning, !processExistsAtOSLevel(pid) {
            break
          }
        }
      } catch is CancellationError {
        terminated = true
        process.terminate()
      }

      // Async-safe wait: avoid process.waitUntilExit() which is a synchronous
      // blocking call that can hang when Foundation's dispatch source misses
      // the process exit notification.
      if terminated || timedOut {
        // Give the process up to 3s to exit after SIGTERM.
        let sigtermDeadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < sigtermDeadline {
          try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // Escalate to SIGKILL if the process is still alive.
        if process.isRunning {
          kill(pid, SIGKILL)
          let sigkillDeadline = Date().addingTimeInterval(2)
          while process.isRunning, Date() < sigkillDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
          }
        }
      }

      try? outputHandle.close()

      let data = (try? Data(contentsOf: outputURL)) ?? Data()
      let output = String(decoding: data, as: UTF8.self)

      // On Linux, Process.terminationStatus traps (SIGILL) if Foundation's
      // internal dispatch source hasn't fully processed the exit. This is a
      // TOCTOU race: even checking isRunning first is not safe — isRunning
      // can return false while the internal state needed by terminationStatus
      // is still inconsistent.
      //
      // Strategy: try waitpid(WNOHANG) first. If the child hasn't been reaped
      // yet by Foundation's dispatch source, we get the status directly. If
      // Foundation already reaped it (waitpid returns -1/ECHILD or 0), we
      // know the dispatch source has processed the exit, so terminationStatus
      // is safe to read.
      let exitCode: Int32
      #if os(Linux)
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        if reaped > 0 {
          // We reaped it ourselves — extract the exit code.
          if (status & 0x7F) == 0 {
            exitCode = (status >> 8) & 0xFF
          } else {
            exitCode = -Int32(status & 0x7F)
          }
        } else if reaped == -1 {
          // ECHILD: Foundation already reaped this child. Its dispatch source
          // has processed the termination, so terminationStatus is safe.
          // But guard with process.isRunning just in case — if still true,
          // use a fallback code rather than risk SIGILL.
          if !process.isRunning {
            exitCode = process.terminationStatus
          } else {
            exitCode = terminated ? -1 : (timedOut ? -1 : 0)
          }
        } else {
          // reaped == 0: child still running (shouldn't happen since our
          // polling loop exited). Wait briefly then retry.
          try? await Task.sleep(nanoseconds: 50_000_000)
          var status2: Int32 = 0
          let reaped2 = waitpid(pid, &status2, WNOHANG)
          if reaped2 > 0 {
            if (status2 & 0x7F) == 0 {
              exitCode = (status2 >> 8) & 0xFF
            } else {
              exitCode = -Int32(status2 & 0x7F)
            }
          } else if !process.isRunning {
            exitCode = process.terminationStatus
          } else {
            exitCode = terminated ? -1 : (timedOut ? -1 : 0)
          }
        }
      #else
        exitCode = process.terminationStatus
      #endif
      return BashResult(exitCode: exitCode, output: output, timedOut: timedOut, terminated: terminated, fullOutputPath: outputURL.path)
    #else
      throw PiAIError.unsupported("bash is not supported on this platform")
    #endif
  }
}

/// Check whether a process still exists at the OS level, bypassing Foundation's
/// internal bookkeeping. Returns false when the PID no longer refers to a live
/// process (ESRCH).
private func processExistsAtOSLevel(_ pid: Int32) -> Bool {
  kill(pid, 0) != -1 || errno != ESRCH
}

private extension String {
  func nilIfEmpty() -> String? {
    isEmpty ? nil : self
  }
}
