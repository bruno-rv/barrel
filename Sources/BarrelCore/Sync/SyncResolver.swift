import Foundation

public struct SyncRecord: Equatable, Sendable {
  public var item: ShelfItem
  public var assetsByRelativePath: [String: URL]

  public init(item: ShelfItem, assetsByRelativePath: [String: URL] = [:]) {
    self.item = item
    self.assetsByRelativePath = assetsByRelativePath
  }

  public init(item: ShelfItem, assetURL: URL?) {
    self.item = item
    if let path = item.relativePath, let assetURL {
      assetsByRelativePath = [path: assetURL]
    } else {
      assetsByRelativePath = [:]
    }
  }

  public var assetURL: URL? {
    guard let path = item.relativePath else { return nil }
    return assetsByRelativePath[path]
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
    try Task.checkCancellation()
    let merged = merge(local: local, remote: remote)
    let localByID = latestRecordsByID(local)
    let remoteByID = latestRecordsByID(remote)
    let recordsToPush = merged.filter { mergedRecord in
      guard let localRecord = localByID[mergedRecord.item.id] else { return false }
      guard let remoteRecord = remoteByID[mergedRecord.item.id] else { return true }
      if SyncResolver.isNewer(localRecord.item, than: remoteRecord.item) {
        return true
      }
      return localRecord.item == remoteRecord.item
        && !Set(localRecord.assetsByRelativePath.keys)
          .isSubset(of: Set(remoteRecord.assetsByRelativePath.keys))
    }
    if !recordsToPush.isEmpty {
      try Task.checkCancellation()
      try await transport.push(recordsToPush)
    }
    try Task.checkCancellation()
    return merged
  }

  public static func merge(local: [SyncRecord], remote: [SyncRecord]) -> [SyncRecord] {
    let localByID = latestRecordsByID(local)
    let remoteByID = latestRecordsByID(remote)
    let mergedItems = SyncResolver.merge(
      local: localByID.values.map(\.item),
      remote: remoteByID.values.map(\.item)
    )
    return mergedItems.map { item in
      let localRecord = localByID[item.id]
      let remoteRecord = remoteByID[item.id]
      if let localRecord, let remoteRecord, localRecord.item == remoteRecord.item {
        let assets = remoteRecord.assetsByRelativePath.merging(
          localRecord.assetsByRelativePath,
          uniquingKeysWith: { _, local in local }
        )
        return SyncRecord(item: item, assetsByRelativePath: assets)
      }
      if let localRecord, localRecord.item == item {
        return localRecord
      }
      guard let remoteRecord else {
        preconditionFailure("Merged sync item has no source record")
      }
      return remoteRecord
    }
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
