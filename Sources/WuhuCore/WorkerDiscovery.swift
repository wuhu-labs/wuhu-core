import Foundation

public enum WorkerDirectory {
  public static func directoryName(runnerName: String, epoch: Int) -> String {
    "\(runnerName).worker.\(epoch)"
  }

  public static func parse(directoryName: String) -> (runnerName: String, epoch: Int)? {
    guard let workerRange = directoryName.range(of: ".worker.") else { return nil }
    let name = String(directoryName[directoryName.startIndex ..< workerRange.lowerBound])
    let epochString = String(directoryName[workerRange.upperBound...])
    guard !name.isEmpty, let epoch = Int(epochString) else { return nil }
    return (name, epoch)
  }

  public static func sortedByEpoch(_ names: [String]) -> [String] {
    names.sorted { (parse(directoryName: $0)?.epoch ?? 0) < (parse(directoryName: $1)?.epoch ?? 0) }
  }

  public static func workerPath(workersRoot: String, runnerName: String, epoch: Int) -> String {
    (workersRoot as NSString).appendingPathComponent(directoryName(runnerName: runnerName, epoch: epoch))
  }

  public static func socketPath(workerDir: String) -> String {
    (workerDir as NSString).appendingPathComponent("socket")
  }

  public static func outputPath(workerDir: String) -> String {
    (workerDir as NSString).appendingPathComponent("output")
  }
}

public protocol WorkerConnectionHandle: Sendable {
  var runner: any Runner { get }
  func startCallbackListener() async
  func close() async
}

public protocol WorkerConnector: Sendable {
  func connect(socketPath: String) async throws -> any WorkerConnectionHandle
}

public protocol LockProvider: Sendable {
  func acquireExclusive(path: String) throws -> LockHandle
}

public protocol LockHandle: Sendable {
  func release()
}

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

public struct FlockLockProvider: LockProvider {
  public init() {}

  public func acquireExclusive(path: String) throws -> LockHandle {
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else {
      throw WorkerDiscoveryError.lockOpenFailed(path: path, errno: errno)
    }
    let result = flock(fd, LOCK_EX | LOCK_NB)
    if result != 0 {
      let err = errno
      close(fd)
      throw WorkerDiscoveryError.lockAlreadyHeld(path: path, errno: err)
    }
    return FlockHandle(fd: fd)
  }
}

public struct FlockHandle: LockHandle, Sendable {
  private let fd: Int32

  init(fd: Int32) {
    self.fd = fd
  }

  public func release() {
    flock(fd, LOCK_UN)
    close(fd)
  }
}

public enum WorkerProbeResult: Sendable {
  case alive(connection: any WorkerConnectionHandle)
  case dead(results: [BashFinished])
}

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
  let workerDirs = WorkerDirectory.sortedByEpoch(entries.filter { $0.hasPrefix(prefix) })

  var results: [(directory: String, result: WorkerProbeResult)] = []
  for dirName in workerDirs {
    let dirPath = (workersRoot as NSString).appendingPathComponent(dirName)
    let socketPath = WorkerDirectory.socketPath(workerDir: dirPath)

    do {
      let connection = try await connector.connect(socketPath: socketPath)
      results.append((dirName, .alive(connection: connection)))
    } catch {
      let outputDir = WorkerDirectory.outputPath(workerDir: dirPath)
      results.append((dirName, .dead(results: parseResultFiles(outputDir: outputDir, fileIO: fileIO))))
    }
  }

  return results
}

public func parseResultFiles(outputDir: String, fileIO: some FileIO) -> [BashFinished] {
  guard let entries = try? fileIO.contentsOfDirectory(atPath: outputDir) else {
    return []
  }

  var results: [BashFinished] = []
  for entry in entries where entry.hasSuffix(".result") {
    let path = (outputDir as NSString).appendingPathComponent(entry)
    guard let data = try? fileIO.readData(path: path), !data.isEmpty else { continue }
    guard let finished = try? JSONDecoder().decode(BashFinished.self, from: data) else { continue }
    results.append(finished)
  }
  return results
}

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
