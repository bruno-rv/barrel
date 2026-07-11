import Foundation

public enum ShelfExpirationPreset: String, CaseIterable, Codable, Sendable {
  case oneHour
  case oneDay
  case oneWeek
  case never

  public func expirationDate(from date: Date) -> Date? {
    switch self {
    case .oneHour: date.addingTimeInterval(3_600)
    case .oneDay: date.addingTimeInterval(86_400)
    case .oneWeek: date.addingTimeInterval(604_800)
    case .never: nil
    }
  }
}

public struct RetentionPolicy: Sendable {
  public let clipboardLifetime: TimeInterval

  public init(clipboardLifetime: TimeInterval = 86_400) {
    self.clipboardLifetime = clipboardLifetime
  }

  public func expirationDate(for origin: ShelfOrigin, now: Date) -> Date? {
    origin == .clipboard ? now.addingTimeInterval(clipboardLifetime) : nil
  }

  public func cleanupCandidates(
    items: [ShelfItem],
    now: Date,
    bytesByItemID: [UUID: Int64],
    quotaBytes: Int64
  ) -> [UUID] {
    let liveItems = items.filter { $0.trashedAt == nil && $0.deletedAt == nil }
    var projectedBytes = liveItems.reduce(Int64(0)) { total, item in
      total + max(bytesByItemID[item.id] ?? 0, 0)
    }
    var candidates: [UUID] = []

    let expired = liveItems
      .filter { $0.isExpired(at: now) }
      .sorted(by: cleanupOrder)
    for item in expired {
      candidates.append(item.id)
      projectedBytes -= max(bytesByItemID[item.id] ?? 0, 0)
    }

    if projectedBytes > max(quotaBytes, 0) {
      let expiredIDs = Set(candidates)
      let clipboardItems = liveItems
        .filter {
          $0.origin == .clipboard
            && !$0.containsPinnedItem
            && !expiredIDs.contains($0.id)
        }
        .sorted(by: cleanupOrder)
      for item in clipboardItems where projectedBytes > max(quotaBytes, 0) {
        candidates.append(item.id)
        projectedBytes -= max(bytesByItemID[item.id] ?? 0, 0)
      }
    }

    return candidates
  }

  private func cleanupOrder(_ lhs: ShelfItem, _ rhs: ShelfItem) -> Bool {
    if lhs.createdAt != rhs.createdAt {
      return lhs.createdAt < rhs.createdAt
    }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}
