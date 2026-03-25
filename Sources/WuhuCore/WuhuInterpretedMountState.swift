import Foundation
import WuhuAPI

struct WuhuInterpretedMountState: Sendable, Equatable {
  private(set) var mountsByID: [String: WuhuMount] = [:]
  private(set) var mountIDsByName: [String: String] = [:]
  private(set) var primaryMountID: String?

  var mounts: [WuhuMount] {
    mountsByID.values.sorted {
      if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
      return $0.id < $1.id
    }
  }

  var primaryMount: WuhuMount? {
    guard let primaryMountID else { return nil }
    return mountsByID[primaryMountID]
  }

  func mount(named name: String) -> WuhuMount? {
    guard let id = mountIDsByName[name] else { return nil }
    return mountsByID[id]
  }

  mutating func apply(_ mount: WuhuMount) {
    if mount.isPrimary {
      clearPrimaryFlag()
      primaryMountID = mount.id
    } else if primaryMountID == mount.id {
      primaryMountID = nil
    }

    mountsByID[mount.id] = mount
    mountIDsByName[mount.name] = mount.id
  }

  private mutating func clearPrimaryFlag() {
    guard let primaryMountID, var existing = mountsByID[primaryMountID] else { return }
    existing.isPrimary = false
    mountsByID[primaryMountID] = existing
  }
}
