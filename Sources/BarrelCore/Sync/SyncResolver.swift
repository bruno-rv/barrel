import Foundation

public enum SyncResolver {
  public static func merge(local: [ShelfItem], remote: [ShelfItem]) -> [ShelfItem] {
    var itemsByID: [UUID: ShelfItem] = [:]

    for item in local + remote {
      guard let current = itemsByID[item.id] else {
        itemsByID[item.id] = item
        continue
      }
      if isNewer(item, than: current) {
        itemsByID[item.id] = item
      }
    }

    return itemsByID.values.sorted { lhs, rhs in
      if lhs.updatedAt != rhs.updatedAt {
        return lhs.updatedAt > rhs.updatedAt
      }
      if lhs.modifiedByDeviceID != rhs.modifiedByDeviceID {
        return lhs.modifiedByDeviceID > rhs.modifiedByDeviceID
      }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  private static func isNewer(_ candidate: ShelfItem, than current: ShelfItem) -> Bool {
    if candidate.updatedAt != current.updatedAt {
      return candidate.updatedAt > current.updatedAt
    }
    return candidate.modifiedByDeviceID > current.modifiedByDeviceID
  }
}
