import Crypto
import Dependencies
import Foundation

/// Content-addressed blob storage built on top of a ``DataBucket``.
///
/// Blobs are keyed by `{namespace}/sha256-{hex}.{ext}`. The namespace is
/// caller-defined (typically a session ID). Deduplication is automatic —
/// identical data produces the same SHA-256 key.
///
/// Blob URIs follow the format `blob://{namespace}/sha256-{hex}.{ext}`.
public struct BlobBucket: Sendable {
  private let storage: any DataBucket

  public init(storage: any DataBucket) {
    self.storage = storage
  }

  /// Store binary data and return a blob URI.
  ///
  /// - Parameters:
  ///   - namespace: Grouping key (e.g. session ID).
  ///   - data: Raw binary data to store.
  ///   - mimeType: MIME type (e.g. "image/png").
  /// - Returns: A blob URI like `blob://{namespace}/sha256-{hex}.{ext}`.
  public func store(namespace: String, data: Data, mimeType: String) async throws -> String {
    let hash = SHA256.hash(data: data)
    let hex = hash.map { String(format: "%02x", $0) }.joined()
    let ext = Self.extensionForMimeType(mimeType)
    let filename = "sha256-\(hex).\(ext)"
    let key = "\(namespace)/\(filename)"

    if try await !storage.exists(key: key) {
      try await storage.write(key: key, data: data)
    }

    return "blob://\(namespace)/\(filename)"
  }

  /// Resolve a blob URI to file data.
  public func resolve(uri: String) async throws -> Data {
    let key = try Self.parseURI(uri)
    guard let data = try await storage.read(key: key) else {
      throw BlobBucketError.notFound(uri)
    }
    return data
  }

  /// Resolve a blob URI to a base64-encoded string.
  public func resolveToBase64(uri: String) async throws -> String {
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
    return "\(parts[0])/\(parts[1])"
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

// MARK: - Dependency registration

private enum BlobBucketKey: DependencyKey {
  static let liveValue: BlobBucket = .init(storage: LocalDataBucket(rootDirectory: NSTemporaryDirectory() + "wuhu-blobs"))
  static let testValue: BlobBucket = .init(storage: LocalDataBucket(rootDirectory: NSTemporaryDirectory() + "wuhu-blobs-test"))
}

public extension DependencyValues {
  var blobBucket: BlobBucket {
    get { self[BlobBucketKey.self] }
    set { self[BlobBucketKey.self] = newValue }
  }
}
