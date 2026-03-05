import Dependencies
import Foundation

/// Compute a relative path for grep output display.
func relativePathForGrep(file: String, root: String, isDirectoryRoot: Bool) -> String {
  if isDirectoryRoot {
    let rootPath = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
    let filePath = URL(fileURLWithPath: file).resolvingSymlinksInPath().standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    if let rel = filePath.replacingOccurrences(of: prefix, with: "").nilIfEqual(filePath) {
      return rel
    }
    return (filePath as NSString).lastPathComponent
  }
  return (file as NSString).lastPathComponent
}

private extension String {
  func nilIfEqual(_ other: String) -> String? {
    self == other ? nil : self
  }
}

/// Walk a directory tree using FileIO, applying filtering callbacks.
/// Returns relative paths of included entries.
func walkFiles(
  root: String,
  fileIO: any FileIO,
  shouldSkipDescendants: ((_ relativePath: String, _ absolutePath: String, _ isDirectory: Bool) -> Bool)? = nil,
  include: (_ relativePath: String, _ absolutePath: String, _ isDirectory: Bool) -> Bool,
) throws -> [String] {
  let allEntries = try fileIO.enumerateDirectory(atPath: root)

  // Build a set of skipped directory prefixes for shouldSkipDescendants.
  var skippedPrefixes: [String] = []
  var results: [String] = []

  for (rel, abs, isDir) in allEntries {
    // Check if this entry is under a skipped prefix.
    let isUnderSkipped = skippedPrefixes.contains { prefix in
      rel.hasPrefix(prefix)
    }
    if isUnderSkipped { continue }

    if isDir, shouldSkipDescendants?(rel, abs, isDir) == true {
      let prefix = rel.hasSuffix("/") ? rel : rel + "/"
      skippedPrefixes.append(prefix)
      continue
    }

    if include(rel, abs, isDir) {
      results.append(rel)
    }
  }
  return results
}
