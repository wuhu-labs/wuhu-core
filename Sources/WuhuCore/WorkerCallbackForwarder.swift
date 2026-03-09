import Foundation

/// Thin pass-through adapter forwarding worker callbacks upstream.
///
/// One forwarder per worker, all targeting the same upstream
/// ``RunnerCallbacks`` (the runner's ``MuxCallbackSender`` to the server).
public actor WorkerCallbackForwarder: RunnerCallbacks {
  private let upstream: any RunnerCallbacks

  public init(upstream: any RunnerCallbacks) {
    self.upstream = upstream
  }

  public func bashOutput(tag: String, chunk: String) async throws {
    try await upstream.bashOutput(tag: tag, chunk: chunk)
  }

  public func bashFinished(tag: String, result: BashResult) async throws {
    try await upstream.bashFinished(tag: tag, result: result)
  }
}
