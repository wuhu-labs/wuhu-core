import Foundation
import Logging

/// Provides a shared debug logger gated behind the `WUHU_DEBUG=1` environment variable.
///
/// When `WUHU_DEBUG=1` is set, the bootstrap sets the global log level to `.debug`.
/// All subsystem loggers created via ``logger(_:)`` will then emit debug-level output.
/// When not set, the default log level remains `.info` and debug messages are silently dropped.
public enum WuhuDebugLogger {
  /// Whether `WUHU_DEBUG=1` is set in the environment.
  public static let isEnabled: Bool = ProcessInfo.processInfo.environment["WUHU_DEBUG"] == "1"

  /// Call once at process startup (before any Logger is created) to configure
  /// the swift-log bootstrap with the appropriate log level.
  public static func bootstrapIfNeeded() {
    guard isEnabled else { return }
    LoggingSystem.bootstrap { label in
      var handler = StreamLogHandler.standardError(label: label)
      handler.logLevel = .debug
      return handler
    }
  }

  /// Create a subsystem logger with the given label.
  /// The log level is determined by the bootstrap (debug when `WUHU_DEBUG=1`).
  public static func logger(_ label: String) -> Logger {
    Logger(label: label)
  }
}
