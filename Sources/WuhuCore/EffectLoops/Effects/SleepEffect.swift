/// Effect factory: sleep until a given instant, then send `.inference(.retryReady)`.
extension AgentBehavior {
  func sleepUntil(_ instant: ContinuousClock.Instant) -> AgentEffect {
    .run("retry-sleep") { send in
      try? await Task.sleep(until: instant, clock: .continuous)
      await send(AgentAction.inference(.retryReady))
    }
  }
}
