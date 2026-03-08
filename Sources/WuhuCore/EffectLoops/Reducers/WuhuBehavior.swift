/// LoopBehavior implementation for the Wuhu agent loop.
///
/// Dispatches actions to sub-reducers. `nextEffect` is a stub
/// returning nil — full implementation comes in Step 2.
struct WuhuBehavior: LoopBehavior {
  typealias State = WuhuState
  typealias Action = WuhuAction

  func reduce(state: inout WuhuState, action: WuhuAction) {
    switch action {
    case let .queue(a):
      reduceQueue(state: &state, action: a)
    case let .inference(a):
      reduceInference(state: &state, action: a)
    case let .tools(a):
      reduceTools(state: &state, action: a)
    case let .cost(a):
      reduceCost(state: &state, action: a)
    case let .transcript(a):
      reduceTranscript(state: &state, action: a)
    case let .settings(a):
      reduceSettings(state: &state, action: a)
    case let .status(a):
      reduceStatus(state: &state, action: a)
    }
  }

  func nextEffect(state _: inout WuhuState) -> Effect<WuhuAction>? {
    // Stub — full priority ladder implementation in Step 2.
    nil
  }
}
