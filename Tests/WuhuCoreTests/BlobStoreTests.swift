import Foundation
import Testing
import WuhuCore

struct BlobStoreTests {
  private func makeTempDir() throws -> String {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("wuhu-blob-test-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
  }

  @Test func storeAndResolveRoundTrip() throws {
    let root = try makeTempDir()
    let store = WuhuBlobStore(rootDirectory: root)

    let data = Data("hello image".utf8)
    let uri = try store.store(sessionID: "sess-1", data: data, mimeType: "image/png")

    #expect(uri.hasPrefix("blob://sess-1/sha256-"))
    #expect(uri.hasSuffix(".png"))

    let resolved = try store.resolve(uri: uri)
    #expect(resolved == data)
  }

  @Test func resolveToBase64() throws {
    let root = try makeTempDir()
    let store = WuhuBlobStore(rootDirectory: root)

    let data = Data("test data".utf8)
    let uri = try store.store(sessionID: "sess-2", data: data, mimeType: "image/jpeg")

    let base64 = try store.resolveToBase64(uri: uri)
    #expect(base64 == data.base64EncodedString())
  }

  @Test func duplicateDataDeduplicates() throws {
    let root = try makeTempDir()
    let store = WuhuBlobStore(rootDirectory: root)

    let data = Data("same content".utf8)
    let uri1 = try store.store(sessionID: "sess-3", data: data, mimeType: "image/png")
    let uri2 = try store.store(sessionID: "sess-3", data: data, mimeType: "image/png")

    #expect(uri1 == uri2)

    // Only one file should exist.
    let sessionDir = (root as NSString).appendingPathComponent("sess-3")
    let files = try FileManager.default.contentsOfDirectory(atPath: sessionDir)
    #expect(files.count == 1)
  }

  @Test func differentSessionsSameDataDifferentURIs() throws {
    let root = try makeTempDir()
    let store = WuhuBlobStore(rootDirectory: root)

    let data = Data("shared content".utf8)
    let uri1 = try store.store(sessionID: "sess-a", data: data, mimeType: "image/png")
    let uri2 = try store.store(sessionID: "sess-b", data: data, mimeType: "image/png")

    #expect(uri1 != uri2)
    #expect(uri1.contains("sess-a"))
    #expect(uri2.contains("sess-b"))

    // Both should resolve to the same content.
    let resolved1 = try store.resolve(uri: uri1)
    let resolved2 = try store.resolve(uri: uri2)
    #expect(resolved1 == resolved2)
  }

  @Test func invalidURIThrows() throws {
    let root = try makeTempDir()
    let store = WuhuBlobStore(rootDirectory: root)

    #expect(throws: (any Error).self) {
      _ = try store.resolve(uri: "not-a-blob-uri")
    }

    #expect(throws: (any Error).self) {
      _ = try store.resolve(uri: "blob://")
    }

    #expect(throws: (any Error).self) {
      _ = try store.filePath(for: "https://example.com/file.png")
    }
  }

  @Test func filePathForURI() throws {
    let root = try makeTempDir()
    let store = WuhuBlobStore(rootDirectory: root)

    let path = try store.filePath(for: "blob://my-session/sha256-abc123.png")
    #expect(path.contains("my-session"))
    #expect(path.contains("sha256-abc123.png"))
    #expect(path.hasPrefix(root))
  }

  @Test func mimeTypeForExtension() {
    #expect(WuhuBlobStore.mimeTypeForExtension("png") == "image/png")
    #expect(WuhuBlobStore.mimeTypeForExtension("jpg") == "image/jpeg")
    #expect(WuhuBlobStore.mimeTypeForExtension("jpeg") == "image/jpeg")
    #expect(WuhuBlobStore.mimeTypeForExtension("gif") == "image/gif")
    #expect(WuhuBlobStore.mimeTypeForExtension("webp") == "image/webp")
    #expect(WuhuBlobStore.mimeTypeForExtension("txt") == nil)
    #expect(WuhuBlobStore.mimeTypeForExtension("PDF") == nil)
  }

  @Test func extensionForMimeType() {
    #expect(WuhuBlobStore.extensionForMimeType("image/png") == "png")
    #expect(WuhuBlobStore.extensionForMimeType("image/jpeg") == "jpg")
    #expect(WuhuBlobStore.extensionForMimeType("image/gif") == "gif")
    #expect(WuhuBlobStore.extensionForMimeType("image/webp") == "webp")
    #expect(WuhuBlobStore.extensionForMimeType("application/octet-stream") == "bin")
  }

  @Test func isImageExtension() {
    #expect(WuhuBlobStore.isImageExtension("png") == true)
    #expect(WuhuBlobStore.isImageExtension("PNG") == true)
    #expect(WuhuBlobStore.isImageExtension("jpg") == true)
    #expect(WuhuBlobStore.isImageExtension("gif") == true)
    #expect(WuhuBlobStore.isImageExtension("webp") == true)
    #expect(WuhuBlobStore.isImageExtension("txt") == false)
    #expect(WuhuBlobStore.isImageExtension("swift") == false)
  }
}
