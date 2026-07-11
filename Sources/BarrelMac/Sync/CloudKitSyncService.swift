import BarrelCore
import CloudKit
import Foundation

actor CloudKitSyncService: SyncTransport {
  static let defaultContainerIdentifier = "iCloud.dev.bruno.barrel"

  private let database: CKDatabase
  private let zoneID = CKRecordZone.ID(zoneName: "Barrel", ownerName: CKCurrentUserDefaultName)
  private let stagingRootURL: URL
  private var preparedZone = false
  private lazy var recordPusher = CloudKitRecordPusher(
    store: CloudKitRecordStore(database: database),
    zoneID: zoneID
  )

  init(
    containerIdentifier: String = CloudKitSyncService.defaultContainerIdentifier,
    stagingRootURL: URL? = nil
  ) {
    database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    self.stagingRootURL = stagingRootURL ?? FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("BarrelMac/SyncStaging", isDirectory: true)
  }

  func fetch() async throws -> [SyncRecord] {
    try Task.checkCancellation()
    try await prepareZoneIfNeeded()
    try prepareStaging()
    let query = CKQuery(recordType: "ShelfItem", predicate: NSPredicate(value: true))
    var records: [SyncRecord] = []
    var cursor: CKQueryOperation.Cursor?
    do {
      repeat {
        try Task.checkCancellation()
        let batch = try await queryBatch(query: cursor == nil ? query : nil, cursor: cursor)
        records.append(contentsOf: batch.records)
        cursor = batch.cursor
      } while cursor != nil
      return records
    } catch {
      try? FileManager.default.removeItem(at: stagingRootURL)
      throw error
    }
  }

  func push(_ records: [SyncRecord]) async throws {
    guard !records.isEmpty else { return }
    try Task.checkCancellation()
    try await prepareZoneIfNeeded()
    try await recordPusher.push(records)
    try Task.checkCancellation()
  }

  func removeStagedAssets() {
    try? FileManager.default.removeItem(at: stagingRootURL)
  }

  private func prepareZoneIfNeeded() async throws {
    guard !preparedZone else { return }
    try Task.checkCancellation()
    _ = try await database.save(CKRecordZone(zoneID: zoneID))
    try Task.checkCancellation()
    preparedZone = true
  }

  private func prepareStaging() throws {
    try? FileManager.default.removeItem(at: stagingRootURL)
    try FileManager.default.createDirectory(at: stagingRootURL, withIntermediateDirectories: true)
  }

  private func queryBatch(
    query: CKQuery?,
    cursor: CKQueryOperation.Cursor?
  ) async throws -> (records: [SyncRecord], cursor: CKQueryOperation.Cursor?) {
    let cancellation = CloudOperationCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let state = CloudQueryState()
        let operation = cursor.map(CKQueryOperation.init(cursor:)) ?? CKQueryOperation(query: query!)
        operation.zoneID = zoneID
        operation.recordMatchedBlock = { [stagingRootURL] _, result in
          switch result {
          case .success(let record):
            do { state.append(try Self.decodeAndStage(record, at: stagingRootURL)) }
            catch { state.record(error: error) }
          case .failure(let error): state.record(error: error)
          }
        }
        operation.queryResultBlock = { result in
          switch result {
          case .failure(let error): continuation.resume(throwing: error)
          case .success(let cursor):
            if let error = state.firstError {
              continuation.resume(throwing: error)
            } else {
              continuation.resume(returning: (state.records, cursor))
            }
          }
        }
        cancellation.set(operation)
        database.add(operation)
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  private nonisolated static func decodeAndStage(
    _ record: CKRecord,
    at stagingRootURL: URL
  ) throws -> SyncRecord {
    guard let payload = record["payload"] as? Data else {
      throw CloudKitSyncError.missingPayload(record.recordID.recordName)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let item = try decoder.decode(ShelfItem.self, from: payload)
    let paths = try (record["assetPaths"] as? Data).map {
      try JSONDecoder().decode([String].self, from: $0)
    } ?? []
    var assets: [String: URL] = [:]
    for (index, path) in paths.enumerated() {
      guard let sourceURL = (record["asset\(index)"] as? CKAsset)?.fileURL else {
        throw CloudKitSyncError.missingAsset(path)
      }
      let destination = stagingRootURL
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent(sourceURL.lastPathComponent)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.copyItem(at: sourceURL, to: destination)
      assets[path] = destination
    }
    return SyncRecord(item: item, assetsByRelativePath: assets)
  }
}

protocol CloudRecordStore: Sendable {
  func fetchRecords(with recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: CKRecord]
  func saveRecords(
    _ records: [CKRecord],
    savePolicy: CKModifyRecordsOperation.RecordSavePolicy
  ) async throws
}

struct CloudKitRecordPusher: Sendable {
  private let store: any CloudRecordStore
  private let zoneID: CKRecordZone.ID

  init(store: any CloudRecordStore, zoneID: CKRecordZone.ID) {
    self.store = store
    self.zoneID = zoneID
  }

  func push(_ syncRecords: [SyncRecord]) async throws {
    guard !syncRecords.isEmpty else { return }
    try Task.checkCancellation()
    let recordIDs = syncRecords.map {
      CKRecord.ID(recordName: $0.item.id.uuidString, zoneID: zoneID)
    }
    let existingRecords = try await store.fetchRecords(with: recordIDs)
    try Task.checkCancellation()
    let records = try zip(syncRecords, recordIDs).map { syncRecord, recordID in
      let record = existingRecords[recordID]
        ?? CKRecord(recordType: "ShelfItem", recordID: recordID)
      try update(record, with: syncRecord)
      return record
    }
    // Conflicts intentionally escape so the next sync pass refetches and remerges.
    try await store.saveRecords(records, savePolicy: .ifServerRecordUnchanged)
    try Task.checkCancellation()
  }

  private func update(_ record: CKRecord, with syncRecord: SyncRecord) throws {
    for key in record.allKeys() where Self.isNumberedAssetField(key) {
      record[key] = nil
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    record["payload"] = try encoder.encode(syncRecord.item) as CKRecordValue
    record["updatedAt"] = syncRecord.item.updatedAt as CKRecordValue
    record["modifiedByDeviceID"] = syncRecord.item.modifiedByDeviceID as CKRecordValue
    let paths = syncRecord.assetsByRelativePath.keys.sorted()
    record["assetPaths"] = try JSONEncoder().encode(paths) as CKRecordValue
    for (index, path) in paths.enumerated() {
      if let url = syncRecord.assetsByRelativePath[path] {
        record["asset\(index)"] = CKAsset(fileURL: url)
      }
    }
  }

  private static func isNumberedAssetField(_ key: String) -> Bool {
    guard key.hasPrefix("asset") else { return false }
    return Int(key.dropFirst("asset".count)) != nil
  }

  static func preferredWriteError(operationError: Error, recordError: Error?) -> Error {
    recordError ?? operationError
  }
}

private final class CloudKitRecordStore: CloudRecordStore, @unchecked Sendable {
  private let database: CKDatabase

  init(database: CKDatabase) {
    self.database = database
  }

  func fetchRecords(with recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: CKRecord] {
    guard !recordIDs.isEmpty else { return [:] }
    let cancellation = CloudOperationCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let state = CloudFetchRecordsState()
        let operation = CKFetchRecordsOperation(recordIDs: recordIDs)
        operation.perRecordResultBlock = { recordID, result in
          state.record(recordID: recordID, result: result)
        }
        operation.fetchRecordsResultBlock = { result in
          switch result {
          case .failure(let error): continuation.resume(throwing: error)
          case .success:
            if let error = state.firstError {
              continuation.resume(throwing: error)
            } else {
              continuation.resume(returning: state.records)
            }
          }
        }
        cancellation.set(operation)
        database.add(operation)
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  func saveRecords(
    _ records: [CKRecord],
    savePolicy: CKModifyRecordsOperation.RecordSavePolicy
  ) async throws {
    let cancellation = CloudOperationCancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let state = CloudOperationState()
        let operation = CKModifyRecordsOperation(recordsToSave: records)
        operation.savePolicy = savePolicy
        operation.isAtomic = false
        operation.perRecordSaveBlock = { _, result in
          if case .failure(let error) = result { state.record(error: error) }
        }
        operation.modifyRecordsResultBlock = { result in
          switch result {
          case .failure(let error):
            continuation.resume(
              throwing: CloudKitRecordPusher.preferredWriteError(
                operationError: error,
                recordError: state.firstError
              )
            )
          case .success:
            if let error = state.firstError {
              continuation.resume(throwing: error)
            } else {
              continuation.resume()
            }
          }
        }
        cancellation.set(operation)
        database.add(operation)
      }
    } onCancel: {
      cancellation.cancel()
    }
  }
}

private final class CloudQueryState: @unchecked Sendable {
  private let lock = NSLock()
  private var storedRecords: [SyncRecord] = []
  private var storedError: Error?
  var records: [SyncRecord] { lock.withLock { storedRecords } }
  var firstError: Error? { lock.withLock { storedError } }
  func append(_ record: SyncRecord) { lock.withLock { storedRecords.append(record) } }
  func record(error: Error) { lock.withLock { if storedError == nil { storedError = error } } }
}

private final class CloudFetchRecordsState: @unchecked Sendable {
  private let lock = NSLock()
  private var storedRecords: [CKRecord.ID: CKRecord] = [:]
  private var storedError: Error?
  var records: [CKRecord.ID: CKRecord] { lock.withLock { storedRecords } }
  var firstError: Error? { lock.withLock { storedError } }

  func record(recordID: CKRecord.ID, result: Result<CKRecord, Error>) {
    lock.withLock {
      switch result {
      case .success(let record):
        storedRecords[recordID] = record
      case .failure(let error as CKError) where error.code == .unknownItem:
        break
      case .failure(let error):
        if storedError == nil { storedError = error }
      }
    }
  }
}

private final class CloudOperationState: @unchecked Sendable {
  private let lock = NSLock()
  private var storedError: Error?
  var firstError: Error? { lock.withLock { storedError } }
  func record(error: Error) { lock.withLock { if storedError == nil { storedError = error } } }
}

private final class CloudOperationCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var operation: Operation?
  private var isCancelled = false
  func set(_ operation: Operation) {
    lock.withLock {
      self.operation = operation
      if isCancelled { operation.cancel() }
    }
  }
  func cancel() {
    lock.withLock {
      isCancelled = true
      operation?.cancel()
    }
  }
}

private enum CloudKitSyncError: LocalizedError {
  case missingPayload(String)
  case missingAsset(String)
  var errorDescription: String? {
    switch self {
    case .missingPayload(let recordName): "CloudKit record \(recordName) has no item payload."
    case .missingAsset(let path): "CloudKit record is missing its advertised asset at \(path)."
    }
  }
}
