import Foundation

/// Maximum number of retry attempts for transient inference errors.
private let maxInferenceRetries = 10

/// Sub-reducer for inference actions.
func reduceInference(state: inout AgentState, action: InferenceAction) {
  switch action {
  case .started:
    state.inference.status = .running
    state.inference.lastError = nil

  case .delta:
    // Deltas are observed but don't change reducer state.
    // Inflight text tracking happens in the runtime observation layer.
    break

  case let .completed(message):
    state.inference.status = .idle
    state.inference.retryCount = 0
    state.inference.retryAfter = nil
    state.inference.lastError = nil
    state.inference.pendingCompletion = message

  case .persisted:
    state.inference.pendingCompletion = nil

  case let .failed(error):
    state.inference.lastError = error
    if error.isTransient, state.inference.retryCount < maxInferenceRetries {
      state.inference.retryCount += 1
      let delay = min(Foundation.pow(2, Double(state.inference.retryCount - 1)), 60)
      state.inference.retryAfter = .now + .seconds(delay)
      state.inference.status = .waitingRetry
    } else {
      state.inference.retryCount += 1
      state.inference.status = .failed
    }

  case .retryReady:
    state.inference.retryAfter = nil
    state.inference.status = .idle
  }
}
