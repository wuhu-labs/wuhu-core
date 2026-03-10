import Foundation
import Logging
import ServiceContextModule

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

    let metadataProvider = Logger.MetadataProvider {
      var metadata: Logger.Metadata = [:]
      if let ctx = ServiceContext.current {
        if let sessionID = ctx.sessionID {
          metadata["sessionID"] = "\(sessionID)"
        }
        if let purpose = ctx.llmPurpose {
          metadata["purpose"] = "\(purpose.rawValue)"
        }
      }
      return metadata
    }

    LoggingSystem.bootstrap({ label, metadataProvider in
      var handler = StreamLogHandler.standardError(label: label, metadataProvider: metadataProvider)
      handler.logLevel = .debug
      return handler
    }, metadataProvider: metadataProvider)
  }

  /// Create a subsystem logger with the given label.
  /// The log level is determined by the bootstrap (debug when `WUHU_DEBUG=1`).
  public static func logger(_ label: String) -> Logger {
    Logger(label: label)
  }
}
