import Foundation
import Logging
import ServiceContextModule

/// Bootstraps the swift-log system with stderr output and optional OTel export.
///
/// Log level is controlled by the `logLevel` parameter (defaulting to `.info`).
/// The old `WUHU_DEBUG=1` environment variable gate is removed — use log levels instead.
public enum WuhuDebugLogger {
  /// Call once at process startup (before any Logger is created) to configure
  /// the swift-log bootstrap with stderr output at the specified log level.
  ///
  /// - Parameters:
  ///   - logLevel: The minimum log level for stderr output. Defaults to `.info`.
  ///   - additionalHandlers: Optional extra `LogHandler` factories to multiplex with stderr
  ///     (e.g., an OTel log handler). Each factory receives the label and metadata provider.
  public static func bootstrap(
    logLevel: Logger.Level = .info,
    additionalHandlers: [@Sendable (String, Logger.MetadataProvider?) -> LogHandler] = [],
  ) {
    let metadataProvider = Logger.MetadataProvider {
      var metadata: Logger.Metadata = [:]
      if let ctx = ServiceContext.current {
        if let sessionID = ctx.sessionID {
          metadata["sessionID"] = "\(sessionID)"
        }
      }
      return metadata
    }

    LoggingSystem.bootstrap({ label, metadataProvider in
      var stderrHandler = StreamLogHandler.standardError(label: label, metadataProvider: metadataProvider)
      stderrHandler.logLevel = logLevel

      if additionalHandlers.isEmpty {
        return stderrHandler
      }

      var handlers: [LogHandler] = [stderrHandler]
      for factory in additionalHandlers {
        handlers.append(factory(label, metadataProvider))
      }
      return MultiplexLogHandler(handlers)
    }, metadataProvider: metadataProvider)
  }

  /// Create a subsystem logger with the given label.
  public static func logger(_ label: String) -> Logger {
    Logger(label: label)
  }
}
