import BarrelCore
import CloudKit
import Foundation

actor CloudKitSyncService: SyncTransport {
  static let defaultContainerIdentifier = "iCloud.dev.bruno.barrel"

  private let database: CKDatabase
  private let zoneID = CKRecordZone.ID(zoneName: "Barrel", ownerName: CKCurrentUserDefaultName)
  private let stagingRootURL: URL
  private var preparedZone = false

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
    let cloudRecords = try records.map(encode)
    let cancellation = CloudOperationCancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let state = CloudOperationState()
        let operation = CKModifyRecordsOperation(recordsToSave: cloudRecords)
        operation.savePolicy = .changedKeys
        operation.isAtomic = false
        operation.perRecordSaveBlock = { _, result in
          if case .failure(let error) = result { state.record(error: error) }
        }
        operation.modifyRecordsResultBlock = { result in
          switch result {
          case .failure(let error): continuation.resume(throwing: error)
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

  private func encode(_ syncRecord: SyncRecord) throws -> CKRecord {
    let recordID = CKRecord.ID(recordName: syncRecord.item.id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: "ShelfItem", recordID: recordID)
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
    return record
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
      guard let sourceURL = (record["asset\(index)"] as? CKAsset)?.fileURL else { continue }
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

private final class CloudQueryState: @unchecked Sendable {
  private let lock = NSLock()
  private var storedRecords: [SyncRecord] = []
  private var storedError: Error?
  var records: [SyncRecord] { lock.withLock { storedRecords } }
  var firstError: Error? { lock.withLock { storedError } }
  func append(_ record: SyncRecord) { lock.withLock { storedRecords.append(record) } }
  func record(error: Error) { lock.withLock { if storedError == nil { storedError = error } } }
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
  var errorDescription: String? {
    switch self {
    case .missingPayload(let recordName): "CloudKit record \(recordName) has no item payload."
    }
  }
}
