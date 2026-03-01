import Foundation

struct WuhuContextFileSnapshot: Sendable, Hashable {
  var path: String
  var modifiedAt: Date
  var size: UInt64
}

struct WuhuContextFile: Sendable, Hashable {
  var path: String
  var content: String
}

enum WuhuAgentsContextFormatter {
  static func render(files: [WuhuContextFile]) -> String {
    guard !files.isEmpty else { return "" }

    var s = "\n\n# Project Context\n\n"
    s += "Project-specific instructions and guidelines:\n\n"
    for f in files {
      s += "## \(f.path)\n\n"
      s += f.content
      if !s.hasSuffix("\n") { s += "\n" }
      s += "\n"
    }
    return s
  }
}

actor WuhuAgentsContextActor {
  private let cwd: String
  private let environmentRoot: String?
  private let workspaceRoot: String?

  private var cachedSnapshot: [WuhuContextFileSnapshot]?
  private var cachedRendered: String?

  init(cwd: String, environmentRoot: String? = nil, workspaceRoot: String? = nil) {
    self.cwd = cwd
    self.environmentRoot = environmentRoot
    self.workspaceRoot = workspaceRoot
  }

  func contextSection() -> String {
    let candidates = buildCandidates()

    let (sortedSnapshots, files) = Self.loadFilesIfChanged(candidates: candidates, cachedSnapshot: cachedSnapshot)
    if let sortedSnapshots {
      cachedSnapshot = sortedSnapshots
      cachedRendered = WuhuAgentsContextFormatter.render(files: files)
    }

    return cachedRendered ?? ""
  }

  private func buildCandidates() -> [String] {
    var seen = Set<String>()
    var candidates: [String] = []

    func addIfNew(_ path: String) {
      let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
      if seen.insert(resolved).inserted {
        candidates.append(path)
      }
    }

    // Workspace root AGENTS.md comes first (broadest scope).
    if let workspaceRoot {
      addIfNew(URL(fileURLWithPath: workspaceRoot).appendingPathComponent("AGENTS.md").path)
      addIfNew(URL(fileURLWithPath: workspaceRoot).appendingPathComponent("AGENTS.local.md").path)
    }

    // Environment root AGENTS.md comes next.
    if let environmentRoot {
      addIfNew(URL(fileURLWithPath: environmentRoot).appendingPathComponent("AGENTS.md").path)
      addIfNew(URL(fileURLWithPath: environmentRoot).appendingPathComponent("AGENTS.local.md").path)
    }

    // Session CWD AGENTS.md comes last (most specific / narrowest scope).
    addIfNew(URL(fileURLWithPath: cwd).appendingPathComponent("AGENTS.md").path)
    addIfNew(URL(fileURLWithPath: cwd).appendingPathComponent("AGENTS.local.md").path)

    return candidates
  }

  private static func loadFilesIfChanged(
    candidates: [String],
    cachedSnapshot: [WuhuContextFileSnapshot]?,
  ) -> (sortedSnapshots: [WuhuContextFileSnapshot]?, files: [WuhuContextFile]) {
    // Build snapshots in candidate order (preserves logical ordering).
    var orderedSnapshots: [WuhuContextFileSnapshot] = []
    orderedSnapshots.reserveCapacity(candidates.count)

    for path in candidates {
      do {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        guard let type = attrs[.type] as? FileAttributeType, type == .typeRegular else { continue }
        guard let modifiedAt = attrs[.modificationDate] as? Date else { continue }

        let size: UInt64 = if let n = attrs[.size] as? NSNumber {
          n.uint64Value
        } else {
          0
        }

        orderedSnapshots.append(.init(path: path, modifiedAt: modifiedAt, size: size))
      } catch {
        continue
      }
    }

    // Sort a copy for stable cache comparison.
    let sortedSnapshots = orderedSnapshots.sorted { $0.path < $1.path }

    if let cachedSnapshot, cachedSnapshot == sortedSnapshots {
      return (sortedSnapshots: nil, files: [])
    }

    // Load files in candidate order so workspace → environment → cwd ordering is preserved.
    var files: [WuhuContextFile] = []
    files.reserveCapacity(orderedSnapshots.count)

    for snap in orderedSnapshots {
      do {
        let content = try String(contentsOfFile: snap.path, encoding: .utf8)
        files.append(.init(path: snap.path, content: content))
      } catch {
        continue
      }
    }

    return (sortedSnapshots: sortedSnapshots, files: files)
  }
}
