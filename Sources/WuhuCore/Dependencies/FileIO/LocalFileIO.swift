import Foundation

/// Production implementation of ``FileIO`` backed by `FileManager.default` and
/// real filesystem calls.
public struct LocalFileIO: FileIO, Sendable {
  public init() {}

  public func readData(path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path))
  }

  public func readString(path: String, encoding: String.Encoding) throws -> String {
    try String(contentsOfFile: path, encoding: encoding)
  }

  public func writeData(path: String, data: Data, atomically: Bool) throws {
    if atomically {
      try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    } else {
      try data.write(to: URL(fileURLWithPath: path))
    }
  }

  public func writeString(path: String, content: String, atomically: Bool, encoding: String.Encoding) throws {
    try content.write(toFile: path, atomically: atomically, encoding: encoding)
  }

  public func exists(path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
  }

  public func existsAndIsDirectory(path: String) -> (exists: Bool, isDirectory: Bool) {
    var isDir: ObjCBool = false
    let e = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
    return (e, isDir.boolValue)
  }

  public func contentsOfDirectory(atPath path: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: path)
  }

  public func createDirectory(atPath path: String, withIntermediateDirectories: Bool) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: withIntermediateDirectories, attributes: nil)
  }

  public func enumerateDirectory(atPath root: String) throws -> [(relativePath: String, absolutePath: String, isDirectory: Bool)] {
    let fm = FileManager.default
    let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
    guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [], errorHandler: nil) else {
      return []
    }

    var results: [(relativePath: String, absolutePath: String, isDirectory: Bool)] = []
    let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"

    for case let url as URL in enumerator {
      let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
      let abs = resolvedURL.path
      let rel = ToolGlob.normalize(abs.replacingOccurrences(of: prefix, with: ""))
      if rel.isEmpty { continue }

      let values = try? resolvedURL.resourceValues(forKeys: [.isDirectoryKey])
      let isDir = values?.isDirectory ?? false

      // Hard-skip known heavy directories at enumerator level.
      if isDir,
         rel == ".git" || rel.hasPrefix(".git/") ||
         rel == "node_modules" || rel.hasPrefix("node_modules/") ||
         rel == ".build" || rel.hasPrefix(".build/") ||
         rel == ".swiftpm" || rel.hasPrefix(".swiftpm/") ||
         rel == "DerivedData" || rel.hasPrefix("DerivedData/")
      {
        enumerator.skipDescendants()
        continue
      }

      results.append((relativePath: rel, absolutePath: abs, isDirectory: isDir))
    }

    return results
  }
}
