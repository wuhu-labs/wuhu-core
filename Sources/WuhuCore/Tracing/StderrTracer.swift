import Foundation
import Logging
import Tracing

/// A minimal `Tracer` that logs span start/end events to stderr via swift-log.
///
/// Used as the default when no OTel endpoint is configured. Bootstrapped via
/// `InstrumentationSystem.bootstrap(StderrTracer())`.
///
/// When an OTel endpoint is configured, the OTel tracer is bootstrapped instead
/// and this type is not used.
public struct StderrTracer: Tracer, Sendable {
  private let logger: Logger

  public init(logger: Logger = Logger(label: "Tracing")) {
    self.logger = logger
  }

  public func startSpan(
    _ operationName: String,
    context: @autoclosure () -> ServiceContext,
    ofKind kind: SpanKind,
    at instant: @autoclosure () -> some TracerInstant,
    function _: String,
    file _: String,
    line _: UInt,
  ) -> StderrSpan {
    let ctx = context()
    return StderrSpan(
      operationName: operationName,
      context: ctx,
      kind: kind,
      startNanos: instant().nanosecondsSinceEpoch,
      logger: logger,
    )
  }

  public func forceFlush() {}

  public func inject<Carrier, Inject: Injector>(
    _: ServiceContext,
    into _: inout Carrier,
    using _: Inject,
  ) where Carrier == Inject.Carrier {}

  public func extract<Carrier, Extract: Extractor>(
    _: Carrier,
    into _: inout ServiceContext,
    using _: Extract,
  ) where Carrier == Extract.Carrier {}
}

/// A span that accumulates attributes and logs a summary on `end()`.
public final class StderrSpan: Tracing.Span, @unchecked Sendable {
  private let lock = NSLock()

  public let context: ServiceContext
  private let kind: SpanKind
  private let startNanos: UInt64
  private let logger: Logger
  private var _operationName: String
  private var _attributes: SpanAttributes = [:]
  private var _status: SpanStatus?
  private var _events: [SpanEvent] = []
  private var _ended = false

  public var operationName: String {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _operationName
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      _operationName = newValue
    }
  }

  public var attributes: SpanAttributes {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _attributes
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      _attributes = newValue
    }
  }

  public var isRecording: Bool {
    true
  }

  init(
    operationName: String,
    context: ServiceContext,
    kind: SpanKind,
    startNanos: UInt64,
    logger: Logger,
  ) {
    self.context = context
    self.kind = kind
    self.startNanos = startNanos
    self.logger = logger
    _operationName = operationName
  }

  public func setStatus(_ status: SpanStatus) {
    lock.lock()
    defer { lock.unlock() }
    _status = status
  }

  public func addEvent(_ event: SpanEvent) {
    lock.lock()
    defer { lock.unlock() }
    _events.append(event)
  }

  public func recordError(
    _: Error,
    attributes: SpanAttributes,
    at instant: @autoclosure () -> some TracerInstant,
  ) {
    addEvent(SpanEvent(name: "exception", at: instant(), attributes: attributes))
  }

  public func addLink(_: SpanLink) {
    // Stderr tracer does not track links.
  }

  public func end(at instant: @autoclosure () -> some TracerInstant) {
    lock.lock()
    guard !_ended else {
      lock.unlock()
      return
    }
    _ended = true
    let name = _operationName
    let attrs = _attributes
    let status = _status
    lock.unlock()

    let endNanos = instant().nanosecondsSinceEpoch
    let durationMs = (endNanos - startNanos) / 1_000_000

    var metadata: Logger.Metadata = [
      "duration_ms": "\(durationMs)",
    ]

    attrs.forEach { key, value in
      metadata[key] = "\(value)"
    }

    if let status, status.code == .error {
      metadata["status"] = "error"
      if let msg = status.message {
        metadata["status_message"] = "\(msg)"
      }
    }

    logger.info("\(name)", metadata: metadata)
  }
}
