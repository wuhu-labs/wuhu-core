import Crypto
import Dependencies
import Foundation

/// Content-addressed blob storage built on top of ``DataBucket``.
///
/// Not a dependency itself — reads `@Dependency(\.dataBucket)` internally.
/// Keys are `blobs/{namespace}/sha256-{hex}.{ext}`. The namespace is
/// caller-defined (typically a session ID).
public enum BlobBucket {
  /// Store binary data and return a blob URI.
  ///
  /// - Parameters:
  ///   - namespace: Grouping key (e.g. session ID).
  ///   - data: Raw binary data to store.
  ///   - mimeType: MIME type (e.g. "image/png").
  /// - Returns: A blob URI like `blob://{namespace}/sha256-{hex}.{ext}`.
  public static func store(namespace: String, data: Data, mimeType: String) async throws -> String {
    @Dependency(\.dataBucket) var dataBucket

    let hash = SHA256.hash(data: data)
    let hex = hash.map { String(format: "%02x", $0) }.joined()
    let ext = extensionForMimeType(mimeType)
    let filename = "sha256-\(hex).\(ext)"
    let key = "blobs/\(namespace)/\(filename)"

    if try await !dataBucket.exists(key: key) {
      try await dataBucket.write(key: key, data: data)
    }

    return "blob://\(namespace)/\(filename)"
  }

  /// Resolve a blob URI to file data.
  public static func resolve(uri: String) async throws -> Data {
    @Dependency(\.dataBucket) var dataBucket

    let key = try parseURI(uri)
    guard let data = try await dataBucket.read(key: key) else {
      throw BlobBucketError.notFound(uri)
    }
    return data
  }

  /// Resolve a blob URI to a base64-encoded string.
  public static func resolveToBase64(uri: String) async throws -> String {
    let data = try await resolve(uri: uri)
    return data.base64EncodedString()
  }

  // MARK: - URI parsing

  /// Parse a `blob://` URI into a storage key.
  static func parseURI(_ uri: String) throws -> String {
    guard uri.hasPrefix("blob://") else {
      throw BlobBucketError.invalidURI(uri)
    }
    let remainder = String(uri.dropFirst("blob://".count))
    let parts = remainder.split(separator: "/", maxSplits: 1)
    guard parts.count == 2 else {
      throw BlobBucketError.invalidURI(uri)
    }
    return "blobs/\(parts[0])/\(parts[1])"
  }

  // MARK: - MIME / extension helpers

  /// Detect MIME type from file extension.
  public static func mimeTypeForExtension(_ ext: String) -> String? {
    switch ext.lowercased() {
    case "png": "image/png"
    case "jpg", "jpeg": "image/jpeg"
    case "gif": "image/gif"
    case "webp": "image/webp"
    default: nil
    }
  }

  /// Get file extension for a MIME type.
  public static func extensionForMimeType(_ mimeType: String) -> String {
    switch mimeType.lowercased() {
    case "image/png": "png"
    case "image/jpeg": "jpg"
    case "image/gif": "gif"
    case "image/webp": "webp"
    default: "bin"
    }
  }

  /// Whether the given file extension is a recognized image format.
  public static func isImageExtension(_ ext: String) -> Bool {
    mimeTypeForExtension(ext) != nil
  }

  /// Maximum supported image file size (10 MB).
  public static let maxImageFileSize = 10 * 1024 * 1024
}

// MARK: - Errors

public enum BlobBucketError: Error, CustomStringConvertible {
  case invalidURI(String)
  case notFound(String)
  case fileTooLarge(path: String, size: Int)

  public var description: String {
    switch self {
    case let .invalidURI(uri): "Invalid blob URI: \(uri)"
    case let .notFound(uri): "Blob not found: \(uri)"
    case let .fileTooLarge(path, size):
      "Image file too large: \(path) (\(size / 1024 / 1024)MB). Max supported: \(BlobBucket.maxImageFileSize / 1024 / 1024)MB"
    }
  }
}
