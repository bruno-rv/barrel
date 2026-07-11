import BarrelCore
import CloudKit
import Foundation
import XCTest
@testable import BarrelMac

final class CloudKitSyncServiceTests: XCTestCase {
  private let zoneID = CKRecordZone.ID(zoneName: "Tests", ownerName: CKCurrentUserDefaultName)

  func testPushMutatesFetchedRecordAndClearsAssetsRemovedByShrinkingSet() async throws {
    let itemID = UUID()
    let oldAsset = try makeAsset(contents: "old")
    let currentAsset = try makeAsset(contents: "current")
    let record = try makeRecord(item: makeItem(id: itemID, title: "Old"))
    record["asset0"] = CKAsset(fileURL: oldAsset)
    record["asset1"] = CKAsset(fileURL: oldAsset)
    record["asset2"] = CKAsset(fileURL: oldAsset)
    let store = FakeCloudRecordStore(record: record)
    let pusher = CloudKitRecordPusher(store: store, zoneID: zoneID)
    let path = "Items/current.txt"

    try await pusher.push([
      SyncRecord(
        item: makeItem(id: itemID, title: "Current", relativePath: path),
        assetsByRelativePath: [path: currentAsset]
      )
    ])

    let saved = try XCTUnwrap(store.savedRecord)
    XCTAssertEqual(store.savedPolicy, .ifServerRecordUnchanged)
    XCTAssertEqual(store.fetchedObjectIdentifier, store.savedObjectIdentifier)
    XCTAssertNotNil(saved["asset0"] as? CKAsset)
    XCTAssertNil(saved["asset1"])
    XCTAssertNil(saved["asset2"])
  }

  func testPushClearsAllNumberedAssetsForTombstone() async throws {
    let itemID = UUID()
    let oldAsset = try makeAsset(contents: "old")
    let record = try makeRecord(item: makeItem(id: itemID, title: "Old"))
    record["asset0"] = CKAsset(fileURL: oldAsset)
    record["asset1"] = CKAsset(fileURL: oldAsset)
    let store = FakeCloudRecordStore(record: record)
    let pusher = CloudKitRecordPusher(store: store, zoneID: zoneID)
    var tombstone = makeItem(id: itemID, title: "Deleted")
    tombstone.deletedAt = Date(timeIntervalSince1970: 1_800_000_100)

    try await pusher.push([SyncRecord(item: tombstone)])

    let saved = try XCTUnwrap(store.savedRecord)
    XCTAssertEqual(store.savedPolicy, .ifServerRecordUnchanged)
    XCTAssertNil(saved["asset0"])
    XCTAssertNil(saved["asset1"])
  }

  func testConcurrentServerChangeIsSurfacedWithoutOverwritingNewerRecord() async throws {
    let itemID = UUID()
    let original = makeItem(id: itemID, title: "Original")
    var local = makeItem(id: itemID, title: "Local")
    local.updatedAt = Date(timeIntervalSince1970: 1_800_000_010)
    var concurrent = makeItem(id: itemID, title: "Concurrent server")
    concurrent.updatedAt = Date(timeIntervalSince1970: 1_800_000_020)
    let store = FakeCloudRecordStore(
      record: try makeRecord(item: original),
      concurrentItemBeforeSave: concurrent
    )
    let pusher = CloudKitRecordPusher(store: store, zoneID: zoneID)

    do {
      try await pusher.push([SyncRecord(item: local)])
      XCTFail("Expected optimistic-concurrency conflict")
    } catch let error as CKError {
      XCTAssertEqual(error.code, .serverRecordChanged)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertEqual(store.savedPolicy, .ifServerRecordUnchanged)
    XCTAssertEqual(try decodeItem(from: store.serverRecord).title, "Concurrent server")
  }

  func testPerRecordConflictIsSurfacedInsteadOfAggregateOperationError() {
    let error = CloudKitRecordPusher.preferredWriteError(
      operationError: CKError(.partialFailure),
      recordError: CKError(.serverRecordChanged)
    ) as? CKError

    XCTAssertEqual(error?.code, .serverRecordChanged)
  }

  func testAllMissingFetchResultsAllowPushToCreateFreshRecords() async throws {
    let item = makeItem(id: UUID(), title: "New")
    let recordID = CKRecord.ID(recordName: item.id.uuidString, zoneID: zoneID)
    let state = CloudFetchRecordsState(expectedRecordIDs: [recordID])
    state.record(recordID: recordID, result: .failure(CKError(.unknownItem)))

    let fetched = try state.resolvedRecords(
      for: .failure(CKError(.unknownItem))
    )
    let store = RecordingCloudRecordStore(fetchedRecords: fetched)
    let pusher = CloudKitRecordPusher(store: store, zoneID: zoneID)
    try await pusher.push([SyncRecord(item: item)])

    XCTAssertEqual(store.savedRecords.map(\.recordID), [recordID])
    XCTAssertEqual(store.savedPolicy, .ifServerRecordUnchanged)
  }

  func testMixedExistingAndMissingFetchResultsReuseExistingAndCreateMissingRecord() async throws {
    let existingItem = makeItem(id: UUID(), title: "Existing")
    let newItem = makeItem(id: UUID(), title: "New")
    let existingRecord = try makeRecord(item: existingItem)
    let newRecordID = CKRecord.ID(recordName: newItem.id.uuidString, zoneID: zoneID)
    let state = CloudFetchRecordsState(
      expectedRecordIDs: [existingRecord.recordID, newRecordID]
    )
    state.record(recordID: existingRecord.recordID, result: .success(existingRecord))
    state.record(recordID: newRecordID, result: .failure(CKError(.unknownItem)))

    let fetched = try state.resolvedRecords(
      for: .failure(CKError(.partialFailure))
    )
    let store = RecordingCloudRecordStore(fetchedRecords: fetched)
    let pusher = CloudKitRecordPusher(store: store, zoneID: zoneID)
    try await pusher.push([SyncRecord(item: existingItem), SyncRecord(item: newItem)])

    XCTAssertEqual(Set(store.savedRecords.map(\.recordID)), [existingRecord.recordID, newRecordID])
    XCTAssertTrue(store.savedRecords.first { $0.recordID == existingRecord.recordID } === existingRecord)
  }

  func testFetchAggregationStillPropagatesSeriousPerRecordAndOperationFailures() {
    let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
    let perRecordFailure = CloudFetchRecordsState(expectedRecordIDs: [recordID])
    perRecordFailure.record(
      recordID: recordID,
      result: .failure(CKError(.networkFailure))
    )

    XCTAssertThrowsError(
      try perRecordFailure.resolvedRecords(for: .failure(CKError(.partialFailure)))
    ) { error in
      XCTAssertEqual((error as? CKError)?.code, .networkFailure)
    }

    let operationFailure = CloudFetchRecordsState(expectedRecordIDs: [recordID])
    operationFailure.record(
      recordID: recordID,
      result: .failure(CKError(.unknownItem))
    )
    XCTAssertThrowsError(
      try operationFailure.resolvedRecords(for: .failure(CKError(.notAuthenticated)))
    ) { error in
      XCTAssertEqual((error as? CKError)?.code, .notAuthenticated)
    }
    XCTAssertThrowsError(
      try operationFailure.resolvedRecords(for: .failure(CKError(.operationCancelled)))
    ) { error in
      XCTAssertEqual((error as? CKError)?.code, .operationCancelled)
    }
  }

  private func makeItem(
    id: UUID,
    title: String,
    relativePath: String? = nil
  ) -> ShelfItem {
    ShelfItem(
      id: id,
      title: title,
      kind: relativePath == nil ? .text : .file,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
      fileName: relativePath.map { _ in "current.txt" },
      relativePath: relativePath,
      revision: 1,
      modifiedByDeviceID: "test-mac"
    )
  }

  private func makeRecord(item: ShelfItem) throws -> CKRecord {
    let recordID = CKRecord.ID(recordName: item.id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: "ShelfItem", recordID: recordID)
    record["payload"] = try encode(item) as CKRecordValue
    return record
  }

  private func makeAsset(contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudKitSyncServiceTests-\(UUID().uuidString)")
    try Data(contents.utf8).write(to: url)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
}

private final class FakeCloudRecordStore: CloudRecordStore, @unchecked Sendable {
  private let lock = NSLock()
  private var storedRecord: CKRecord
  private let concurrentItemBeforeSave: ShelfItem?
  private var storedSavedRecord: CKRecord?
  private var storedSavedPolicy: CKModifyRecordsOperation.RecordSavePolicy?
  private var storedFetchedObjectIdentifier: ObjectIdentifier?
  private var storedSavedObjectIdentifier: ObjectIdentifier?

  init(record: CKRecord, concurrentItemBeforeSave: ShelfItem? = nil) {
    storedRecord = record
    self.concurrentItemBeforeSave = concurrentItemBeforeSave
  }

  var savedRecord: CKRecord? { lock.withLock { storedSavedRecord } }
  var serverRecord: CKRecord { lock.withLock { storedRecord } }
  var savedPolicy: CKModifyRecordsOperation.RecordSavePolicy? {
    lock.withLock { storedSavedPolicy }
  }
  var fetchedObjectIdentifier: ObjectIdentifier? {
    lock.withLock { storedFetchedObjectIdentifier }
  }
  var savedObjectIdentifier: ObjectIdentifier? {
    lock.withLock { storedSavedObjectIdentifier }
  }

  func fetchRecords(with recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: CKRecord] {
    lock.withLock {
      let fetched = clone(storedRecord)
      storedFetchedObjectIdentifier = ObjectIdentifier(fetched)
      return [fetched.recordID: fetched]
    }
  }

  func saveRecords(
    _ records: [CKRecord],
    savePolicy: CKModifyRecordsOperation.RecordSavePolicy
  ) async throws {
    try lock.withLock {
      storedSavedPolicy = savePolicy
      let record = try XCTUnwrap(records.first)
      storedSavedObjectIdentifier = ObjectIdentifier(record)
      if let concurrentItemBeforeSave {
        storedRecord["payload"] = try encode(concurrentItemBeforeSave) as CKRecordValue
        if savePolicy == .ifServerRecordUnchanged {
          throw CKError(.serverRecordChanged)
        }
      }
      storedRecord = clone(record)
      storedSavedRecord = record
    }
  }

  private func clone(_ record: CKRecord) -> CKRecord {
    let copy = CKRecord(recordType: record.recordType, recordID: record.recordID)
    for key in record.allKeys() {
      copy[key] = record[key]
    }
    return copy
  }
}

private final class RecordingCloudRecordStore: CloudRecordStore, @unchecked Sendable {
  private let lock = NSLock()
  private let fetchedRecords: [CKRecord.ID: CKRecord]
  private var storedSavedRecords: [CKRecord] = []
  private var storedSavedPolicy: CKModifyRecordsOperation.RecordSavePolicy?

  init(fetchedRecords: [CKRecord.ID: CKRecord]) {
    self.fetchedRecords = fetchedRecords
  }

  var savedRecords: [CKRecord] { lock.withLock { storedSavedRecords } }
  var savedPolicy: CKModifyRecordsOperation.RecordSavePolicy? {
    lock.withLock { storedSavedPolicy }
  }

  func fetchRecords(with recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: CKRecord] {
    fetchedRecords.filter { recordIDs.contains($0.key) }
  }

  func saveRecords(
    _ records: [CKRecord],
    savePolicy: CKModifyRecordsOperation.RecordSavePolicy
  ) async throws {
    lock.withLock {
      storedSavedRecords = records
      storedSavedPolicy = savePolicy
    }
  }
}

private func encode(_ item: ShelfItem) throws -> Data {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  return try encoder.encode(item)
}

private func decodeItem(from record: CKRecord) throws -> ShelfItem {
  let data = try XCTUnwrap(record["payload"] as? Data)
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  return try decoder.decode(ShelfItem.self, from: data)
}
