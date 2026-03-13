import Foundation

public actor WorkerCallbackForwarder: RunnerCallbacks {
  private let upstream: any RunnerCallbacks

  public init(upstream: any RunnerCallbacks) {
    self.upstream = upstream
  }

  public func bashHeartbeat(tag: String) async throws {
    try await upstream.bashHeartbeat(tag: tag)
  }

  public func bashFinished(tag: String, result: BashResult) async throws {
    try await upstream.bashFinished(tag: tag, result: result)
  }
}
