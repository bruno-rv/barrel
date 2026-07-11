import Foundation
import XCTest
@testable import BarrelCore

final class SyncCoordinatorTests: XCTestCase {
  private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

  func testRemoteNewerRecordAndAssetWin() async throws {
    let id = UUID()
    let local = SyncRecord(item: item(id: id, title: "Local", offset: 0, deviceID: "mac-a"))
    let remoteAsset = URL(fileURLWithPath: "/tmp/remote-asset")
    let remote = SyncRecord(
      item: item(id: id, title: "Remote", offset: 1, deviceID: "mac-b"),
      assetURL: remoteAsset
    )
    let transport = InMemorySyncTransport(records: [remote])

    let merged = try await SyncCoordinator.synchronize(local: [local], transport: transport)

    XCTAssertEqual(merged, [remote])
    let pushed = await transport.pushedRecords()
    XCTAssertEqual(pushed, [])
  }

  func testLocalNewerRecordIsPushed() async throws {
    let id = UUID()
    let localAsset = URL(fileURLWithPath: "/tmp/local-asset")
    let local = SyncRecord(
      item: item(id: id, title: "Local", offset: 1, deviceID: "mac-a"),
      assetURL: localAsset
    )
    let remote = SyncRecord(item: item(id: id, title: "Remote", offset: 0, deviceID: "mac-b"))
    let transport = InMemorySyncTransport(records: [remote])

    let merged = try await SyncCoordinator.synchronize(local: [local], transport: transport)

    XCTAssertEqual(merged, [local])
    let pushed = await transport.pushedRecords()
    XCTAssertEqual(pushed, [local])
  }

  func testTombstoneRemainsInMergedResult() async throws {
    let deletionDate = baseDate.addingTimeInterval(2)
    let tombstone = SyncRecord(
      item: item(
        id: UUID(),
        title: "Deleted",
        offset: 2,
        deviceID: "mac-b",
        trashedAt: deletionDate
      )
    )
    let transport = InMemorySyncTransport(records: [tombstone])

    let merged = try await SyncCoordinator.synchronize(local: [], transport: transport)

    XCTAssertEqual(merged, [tombstone])
    XCTAssertEqual(merged.first?.item.trashedAt, deletionDate)
  }

  func testTransportFailureLeavesInputSnapshotUnchanged() async throws {
    let local = [SyncRecord(item: item(id: UUID(), title: "Local", offset: 0, deviceID: "mac-a"))]
    let original = local
    let transport = InMemorySyncTransport(records: [], fetchError: TestError.fetchFailed)

    do {
      _ = try await SyncCoordinator.synchronize(local: local, transport: transport)
      XCTFail("Expected fetch to fail")
    } catch TestError.fetchFailed {
      // Expected.
    }

    XCTAssertEqual(local, original)
    let pushed = await transport.pushedRecords()
    XCTAssertEqual(pushed, [])
  }

  func testCancellationAfterFetchStartsPreventsPush() async throws {
    let local = SyncRecord(item: item(id: UUID(), title: "Local", offset: 1, deviceID: "mac-a"))
    let transport = SuspendedSyncTransport()
    let task = Task {
      try await SyncCoordinator.synchronize(local: [local], transport: transport)
    }
    while !(await transport.isFetching) {
      await Task.yield()
    }

    task.cancel()
    await transport.resumeFetch(with: [])

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    }
    let pushed = await transport.pushedRecords
    XCTAssertTrue(pushed.isEmpty)
  }

  private func item(
    id: UUID,
    title: String,
    offset: TimeInterval,
    deviceID: String,
    trashedAt: Date? = nil
  ) -> ShelfItem {
    ShelfItem(
      id: id,
      title: title,
      kind: .text,
      createdAt: baseDate,
      updatedAt: baseDate.addingTimeInterval(offset),
      trashedAt: trashedAt,
      revision: 1,
      modifiedByDeviceID: deviceID
    )
  }
}

private actor InMemorySyncTransport: SyncTransport {
  private let records: [SyncRecord]
  private let fetchError: Error?
  private var pushed: [SyncRecord] = []

  init(records: [SyncRecord], fetchError: Error? = nil) {
    self.records = records
    self.fetchError = fetchError
  }

  func fetch() async throws -> [SyncRecord] {
    if let fetchError {
      throw fetchError
    }
    return records
  }

  func push(_ records: [SyncRecord]) async throws {
    pushed.append(contentsOf: records)
  }

  func pushedRecords() -> [SyncRecord] {
    pushed
  }
}

private enum TestError: Error {
  case fetchFailed
}

private actor SuspendedSyncTransport: SyncTransport {
  private var continuation: CheckedContinuation<[SyncRecord], Never>?
  private(set) var pushedRecords: [SyncRecord] = []

  var isFetching: Bool { continuation != nil }

  func fetch() async throws -> [SyncRecord] {
    await withCheckedContinuation { continuation = $0 }
  }

  func push(_ records: [SyncRecord]) async throws {
    pushedRecords.append(contentsOf: records)
  }

  func resumeFetch(with records: [SyncRecord]) {
    continuation?.resume(returning: records)
    continuation = nil
  }
}
