import BarrelCore
import CloudKit
import Foundation

actor CloudKitSyncService: SyncTransport {
  static let defaultContainerIdentifier = "iCloud.dev.bruno.barrel"

  private let database: CKDatabase
  private let zoneID = CKRecordZone.ID(zoneName: "Barrel", ownerName: CKCurrentUserDefaultName)
  private var preparedZone = false

  init(containerIdentifier: String = CloudKitSyncService.defaultContainerIdentifier) {
    database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
  }

  func fetch() async throws -> [SyncRecord] {
    try await prepareZoneIfNeeded()
    let query = CKQuery(recordType: "ShelfItem", predicate: NSPredicate(value: true))
    var records: [CKRecord] = []
    var cursor: CKQueryOperation.Cursor?
    repeat {
      let batch = try await queryBatch(query: cursor == nil ? query : nil, cursor: cursor)
      records.append(contentsOf: batch.records)
      cursor = batch.cursor
    } while cursor != nil
    return try records.map(decode)
  }

  func push(_ records: [SyncRecord]) async throws {
    guard !records.isEmpty else { return }
    try await prepareZoneIfNeeded()
    let cloudRecords = try records.map(encode)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let state = CloudOperationState()
      let operation = CKModifyRecordsOperation(recordsToSave: cloudRecords)
      operation.savePolicy = .changedKeys
      operation.isAtomic = false
      operation.perRecordSaveBlock = { _, result in
        if case .failure(let error) = result {
          state.record(error: error)
        }
      }
      operation.modifyRecordsResultBlock = { result in
        switch result {
        case .failure(let error):
          continuation.resume(throwing: error)
        case .success:
          if let error = state.firstError {
            continuation.resume(throwing: error)
          } else {
            continuation.resume()
          }
        }
      }
      database.add(operation)
    }
  }

  private func prepareZoneIfNeeded() async throws {
    guard !preparedZone else { return }
    _ = try await database.save(CKRecordZone(zoneID: zoneID))
    preparedZone = true
  }

  private func queryBatch(
    query: CKQuery?,
    cursor: CKQueryOperation.Cursor?
  ) async throws -> (records: [CKRecord], cursor: CKQueryOperation.Cursor?) {
    try await withCheckedThrowingContinuation { continuation in
      let state = CloudQueryState()
      let operation = cursor.map(CKQueryOperation.init(cursor:)) ?? CKQueryOperation(query: query!)
      operation.zoneID = zoneID
      operation.recordMatchedBlock = { _, result in
        switch result {
        case .success(let record): state.append(record)
        case .failure(let error): state.record(error: error)
        }
      }
      operation.queryResultBlock = { result in
        switch result {
        case .failure(let error):
          continuation.resume(throwing: error)
        case .success(let cursor):
          if let error = state.firstError {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(returning: (state.records, cursor))
          }
        }
      }
      database.add(operation)
    }
  }

  private func encode(_ syncRecord: SyncRecord) throws -> CKRecord {
    let recordID = CKRecord.ID(recordName: syncRecord.item.id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: "ShelfItem", recordID: recordID)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    record["payload"] = try encoder.encode(syncRecord.item) as CKRecordValue
    record["updatedAt"] = syncRecord.item.updatedAt as CKRecordValue
    record["modifiedByDeviceID"] = syncRecord.item.modifiedByDeviceID as CKRecordValue
    if let assetURL = syncRecord.assetURL {
      record["asset"] = CKAsset(fileURL: assetURL)
    }
    return record
  }

  private func decode(_ record: CKRecord) throws -> SyncRecord {
    guard let payload = record["payload"] as? Data else {
      throw CloudKitSyncError.missingPayload(record.recordID.recordName)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let item = try decoder.decode(ShelfItem.self, from: payload)
    let assetURL = (record["asset"] as? CKAsset)?.fileURL
    return SyncRecord(item: item, assetURL: assetURL)
  }
}

private final class CloudQueryState: @unchecked Sendable {
  private let lock = NSLock()
  private var storedRecords: [CKRecord] = []
  private var storedError: Error?

  var records: [CKRecord] { lock.withLock { storedRecords } }
  var firstError: Error? { lock.withLock { storedError } }

  func append(_ record: CKRecord) {
    lock.withLock { storedRecords.append(record) }
  }

  func record(error: Error) {
    lock.withLock {
      if storedError == nil { storedError = error }
    }
  }
}

private final class CloudOperationState: @unchecked Sendable {
  private let lock = NSLock()
  private var storedError: Error?

  var firstError: Error? { lock.withLock { storedError } }

  func record(error: Error) {
    lock.withLock {
      if storedError == nil { storedError = error }
    }
  }
}

private enum CloudKitSyncError: LocalizedError {
  case missingPayload(String)

  var errorDescription: String? {
    switch self {
    case .missingPayload(let recordName):
      "CloudKit record \(recordName) has no item payload."
    }
  }
}
