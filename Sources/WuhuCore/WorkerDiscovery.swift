import Foundation

// MARK: - Worker directory naming

/// Helpers for the `<name>.worker.<epoch>` naming convention.
public enum WorkerDirectory {
  /// Create a worker directory name from a runner name and epoch.
  public static func directoryName(runnerName: String, epoch: Int) -> String {
    "\(runnerName).worker.\(epoch)"
  }

  /// Parse a worker directory name, returning the runner name and epoch.
  /// Returns nil if the name doesn't match the expected format.
  public static func parse(directoryName: String) -> (runnerName: String, epoch: Int)? {
    // Expected format: <name>.worker.<epoch>
    guard let workerRange = directoryName.range(of: ".worker.") else { return nil }
    let name = String(directoryName[directoryName.startIndex ..< workerRange.lowerBound])
    let epochStr = String(directoryName[workerRange.upperBound...])
    guard let epoch = Int(epochStr), !name.isEmpty else { return nil }
    return (runnerName: name, epoch: epoch)
  }

  /// Sort directory names by epoch ascending.
  public static func sortedByEpoch(_ names: [String]) -> [String] {
    names.sorted { a, b in
      let epochA = parse(directoryName: a)?.epoch ?? 0
      let epochB = parse(directoryName: b)?.epoch ?? 0
      return epochA < epochB
    }
  }

  /// Create the full worker directory path under the workers root.
  public static func workerPath(workersRoot: String, runnerName: String, epoch: Int) -> String {
    (workersRoot as NSString).appendingPathComponent(directoryName(runnerName: runnerName, epoch: epoch))
  }

  /// Socket path inside a worker directory.
  public static func socketPath(workerDir: String) -> String {
    (workerDir as NSString).appendingPathComponent("socket")
  }

  /// Output directory inside a worker directory.
  public static func outputPath(workerDir: String) -> String {
    (workerDir as NSString).appendingPathComponent("output")
  }
}

// MARK: - WorkerConnector protocol

/// Abstracts connecting to a worker's UDS mux socket.
/// Real implementation does UDS mux connect; test implementation returns mocks.
public protocol WorkerConnector: Sendable {
  /// Attempt to connect to a worker at the given socket path.
  /// Returns a `RunnerCallbacks` that can be used to receive callbacks from the worker.
  /// Throws if the worker is unreachable.
  func connect(socketPath: String) async throws -> any RunnerCallbacks
}

// MARK: - LockProvider protocol

/// Abstracts file locking for runner identity (`flock()`).
public protocol LockProvider: Sendable {
  /// Acquire an exclusive non-blocking lock on the file at `path`.
  /// Creates the file if it doesn't exist.
  /// Throws if the lock is already held by another process.
  func acquireExclusive(path: String) throws -> LockHandle
}

/// Opaque handle returned by ``LockProvider/acquireExclusive(path:)``.
/// The lock is released when `release()` is called.
public protocol LockHandle: Sendable {
  func release()
}

// MARK: - Real LockProvider (flock-based)

#if canImport(Glibc)
  import Glibc

  /// File-lock provider using `flock()` on Linux.
  public struct FlockLockProvider: LockProvider {
    public init() {}

    public func acquireExclusive(path: String) throws -> LockHandle {
      let fd = Glibc.open(path, O_CREAT | O_RDWR, 0o644)
      guard fd >= 0 else {
        throw WorkerDiscoveryError.lockOpenFailed(path: path, errno: errno)
      }
      // Use the C flock() function — Glibc.flock resolves to the struct, not the function.
      let result = flock(fd, LOCK_EX | LOCK_NB)
      if result != 0 {
        let err = errno
        Glibc.close(fd)
        throw WorkerDiscoveryError.lockAlreadyHeld(path: path, errno: err)
      }
      return FlockHandle(fd: fd)
    }
  }

  /// Lock handle backed by a file descriptor with `flock()`.
  public struct FlockHandle: LockHandle, Sendable {
    private let fd: Int32

    init(fd: Int32) {
      self.fd = fd
    }

    public func release() {
      flock(fd, LOCK_UN)
      Glibc.close(fd)
    }
  }
#endif

// MARK: - Worker discovery

/// Result of scanning a single worker directory.
public enum WorkerProbeResult: Sendable {
  /// Worker is alive and reachable.
  case alive(callbacks: any RunnerCallbacks)
  /// Worker is dead. Contains parsed results from disk.
  case dead(results: [BashFinished])
}

/// Scan worker directories for a given runner name and probe each one.
///
/// - Parameters:
///   - workersRoot: Root directory (e.g. `~/.wuhu/workers/`).
///   - runnerName: Runner name to filter directories for.
///   - fileIO: FileIO dependency for disk access.
///   - connector: WorkerConnector for testing liveness.
/// - Returns: Array of `(directoryName, probeResult)` sorted by epoch ascending.
public func discoverWorkers(
  workersRoot: String,
  runnerName: String,
  fileIO: some FileIO,
  connector: some WorkerConnector,
) async -> [(directory: String, result: WorkerProbeResult)] {
  guard let entries = try? fileIO.contentsOfDirectory(atPath: workersRoot) else {
    return []
  }

  let prefix = "\(runnerName).worker."
  let workerDirs = entries.filter { $0.hasPrefix(prefix) }
  let sorted = WorkerDirectory.sortedByEpoch(workerDirs)

  var results: [(directory: String, result: WorkerProbeResult)] = []

  for dirName in sorted {
    let dirPath = (workersRoot as NSString).appendingPathComponent(dirName)
    let socketPath = WorkerDirectory.socketPath(workerDir: dirPath)

    // Try to connect
    do {
      let callbacks = try await connector.connect(socketPath: socketPath)
      results.append((directory: dirName, result: .alive(callbacks: callbacks)))
    } catch {
      // Dead worker — collect results from disk
      let outputDir = WorkerDirectory.outputPath(workerDir: dirPath)
      let parsedResults = parseResultFiles(outputDir: outputDir, fileIO: fileIO)
      results.append((directory: dirName, result: .dead(results: parsedResults)))
    }
  }

  return results
}

/// Parse `.result` files from a worker's output directory.
public func parseResultFiles(outputDir: String, fileIO: some FileIO) -> [BashFinished] {
  guard let entries = try? fileIO.contentsOfDirectory(atPath: outputDir) else {
    return []
  }

  var results: [BashFinished] = []
  for entry in entries {
    guard entry.hasSuffix(".result") else { continue }
    let path = (outputDir as NSString).appendingPathComponent(entry)
    guard let data = try? fileIO.readData(path: path),
          !data.isEmpty
    else { continue }
    guard let finished = try? JSONDecoder().decode(BashFinished.self, from: data) else { continue }
    results.append(finished)
  }
  return results
}

// MARK: - Errors

public enum WorkerDiscoveryError: Error, Sendable, CustomStringConvertible {
  case lockOpenFailed(path: String, errno: Int32)
  case lockAlreadyHeld(path: String, errno: Int32)

  public var description: String {
    switch self {
    case let .lockOpenFailed(path, errno):
      "Failed to open lock file '\(path)': errno \(errno)"
    case let .lockAlreadyHeld(path, _):
      "Lock already held on '\(path)' — another runner instance is running"
    }
  }
}
