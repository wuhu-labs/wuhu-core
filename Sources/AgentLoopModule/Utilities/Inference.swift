import Dependencies
import DependenciesMacros
import Foundation
import WuhuAI

@DependencyClient
public struct InferenceClient: Sendable {
  public var stream: @Sendable (
    _ model: String,
    _ context: Context,
    _ options: RequestOptions
  ) async throws -> AsyncThrowingStream<AssistantMessageEvent, any Error>
}

extension InferenceClient: TestDependencyKey {
  public static let testValue: InferenceClient = InferenceClient()
}

public struct AutoRetryInference: Sendable {
  public var maxInferenceRetries: Int
  public var sleepBackoff: @Sendable (Int) -> ContinuousClock.Duration

  public init(
    maxInferenceRetries: Int = 5,
    sleepBackoff: (@Sendable (Int) -> ContinuousClock.Duration)? = nil
  ) {
    self.maxInferenceRetries = maxInferenceRetries
    self.sleepBackoff = sleepBackoff ?? { attempt in
      let delay = min(pow(2, Double(attempt - 1)), 60)
      let jitter = delay * Double.random(in: 0.75 ... 1.25)
      return .milliseconds(Int(jitter * 1000))
    }
  }

  public enum Action: Sendable {
    case inferenceStarted(Int)
    case textDelta(String, AssistantMessage)
    case inferenceCompleted(AssistantMessage)
  }

  @Dependency(InferenceClient.self)
  private var inferenceClient
  @Dependency(\.continuousClock)
  private var clock

  public func infer<Interruption: Sendable>(
    model: String, context: Context, options: RequestOptions, interruption: Interruption.Type = Interruption.self
  ) -> DeferredExecution<Action, Interruption> {
    .init { coordinator in
      for attempt in 0..<maxInferenceRetries {
        try Task.checkCancellation()

        if attempt > 0 {
          let delay = min(pow(2, Double(attempt - 1)), 60)
          let jitter = delay * Double.random(in: -0.25 ... 0.25)
          try await clock.sleep(for: .milliseconds(Int(jitter * 1000)))
        }

        do {
          coordinator.send(.inferenceStarted(attempt))
          let stream = try await inferenceClient.stream(model: model, context: context, options: .init())

          var message: AssistantMessage?
          for try await event in stream {
            switch event {
            case let .start(m):
              message = m
            case let .textDelta(d, m):
              coordinator.send(.textDelta(d, m))
              message = m
            case let .done(m):
              message = m
            }
          }
          guard let message else { throw InferenceError.noResult }
          coordinator.send(.inferenceCompleted(message))
        } catch {
          if isTransientError(error) {
            continue
          }
          throw error
        }
      }

      throw InferenceError.maxRetriesExceeded
    }
  }
}

public enum InferenceError: Error {
  case noResult
  case maxRetriesExceeded
}

private func isTransientError(_ error: any Error) -> Bool {
  if let error = error as? WuhuAIError,
     case let .httpStatus(code, _) = error
  {
    return code == 429 || code == 500 || code == 502 || code == 503 || code == 529
  }

  let description = String(describing: error)
  if description.contains("remoteConnectionClosed")
    || description.contains("connectTimeout")
    || description.contains("readTimeout")
  {
    return true
  }

  return false
}
