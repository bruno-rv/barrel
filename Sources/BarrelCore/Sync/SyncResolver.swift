import Foundation

public struct SyncRecord: Equatable, Sendable {
  public var item: ShelfItem
  public var assetURL: URL?

  public init(item: ShelfItem, assetURL: URL? = nil) {
    self.item = item
    self.assetURL = assetURL
  }
}

public protocol SyncTransport: Sendable {
  func fetch() async throws -> [SyncRecord]
  func push(_ records: [SyncRecord]) async throws
}

public enum SyncCoordinator {
  public static func synchronize<Transport: SyncTransport>(
    local: [SyncRecord],
    transport: Transport
  ) async throws -> [SyncRecord] {
    let remote = try await transport.fetch()
    let localByID = latestRecordsByID(local)
    let remoteByID = latestRecordsByID(remote)
    let mergedItems = SyncResolver.merge(
      local: localByID.values.map(\.item),
      remote: remoteByID.values.map(\.item)
    )
    var recordsToPush: [SyncRecord] = []
    let merged = mergedItems.map { item -> SyncRecord in
      let localRecord = localByID[item.id]
      let remoteRecord = remoteByID[item.id]
      if let localRecord, localRecord.item == item,
         remoteRecord?.item != item {
        recordsToPush.append(localRecord)
        return localRecord
      }
      if let remoteRecord, remoteRecord.item == item {
        if remoteRecord.item == localRecord?.item,
           remoteRecord.assetURL == nil,
           let localAssetURL = localRecord?.assetURL {
          return SyncRecord(item: item, assetURL: localAssetURL)
        }
        return remoteRecord
      }
      guard let localRecord else {
        preconditionFailure("Merged sync item has no source record")
      }
      recordsToPush.append(localRecord)
      return localRecord
    }
    if !recordsToPush.isEmpty {
      try await transport.push(recordsToPush)
    }
    return merged
  }

  private static func latestRecordsByID(_ records: [SyncRecord]) -> [UUID: SyncRecord] {
    var recordsByID: [UUID: SyncRecord] = [:]
    for record in records {
      guard let current = recordsByID[record.item.id] else {
        recordsByID[record.item.id] = record
        continue
      }
      if SyncResolver.isNewer(record.item, than: current.item) {
        recordsByID[record.item.id] = record
      }
    }
    return recordsByID
  }
}

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

  static func isNewer(_ candidate: ShelfItem, than current: ShelfItem) -> Bool {
    if candidate.updatedAt != current.updatedAt {
      return candidate.updatedAt > current.updatedAt
    }
    return candidate.modifiedByDeviceID > current.modifiedByDeviceID
  }
}
