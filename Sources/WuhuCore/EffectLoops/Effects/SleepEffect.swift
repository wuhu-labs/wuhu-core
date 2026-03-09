/// Effect factory: sleep until a given instant, then send `.inference(.retryReady)`.
extension WuhuBehavior {
  func sleepUntil(_ instant: ContinuousClock.Instant) -> Effect<WuhuAction> {
    Effect { send in
      try? await Task.sleep(until: instant, clock: .continuous)
      await send(WuhuAction.inference(.retryReady))
    }
  }
}
