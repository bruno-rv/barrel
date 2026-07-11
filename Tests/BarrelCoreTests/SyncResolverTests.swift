import XCTest
@testable import BarrelCore

final class SyncResolverTests: XCTestCase {
  private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

  func testNewerTimestampWins() throws {
    let id = UUID()
    let local = item(id: id, title: "Local", updatedAt: baseDate, deviceID: "mac-a")
    let remote = item(
      id: id,
      title: "Remote",
      updatedAt: baseDate.addingTimeInterval(1),
      deviceID: "mac-b"
    )

    let merged = SyncResolver.merge(local: [local], remote: [remote])

    XCTAssertEqual(merged, [remote])
  }

  func testTimestampTieChoosesLexicographicallyGreaterDeviceID() throws {
    let id = UUID()
    let local = item(id: id, title: "Local", updatedAt: baseDate, deviceID: "mac-a")
    let remote = item(id: id, title: "Remote", updatedAt: baseDate, deviceID: "mac-z")

    let merged = SyncResolver.merge(local: [local], remote: [remote])

    XCTAssertEqual(merged, [remote])
  }

  func testNewerTombstoneWinsOverLiveRecord() throws {
    let id = UUID()
    let local = item(id: id, title: "Live", updatedAt: baseDate, deviceID: "mac-a")
    let remote = item(
      id: id,
      title: "Deleted",
      updatedAt: baseDate.addingTimeInterval(1),
      deviceID: "mac-b",
      trashedAt: baseDate.addingTimeInterval(1)
    )

    let merged = SyncResolver.merge(local: [local], remote: [remote])

    XCTAssertEqual(merged, [remote])
    XCTAssertNotNil(merged.first?.trashedAt)
  }

  func testMergeSortsNewestFirst() throws {
    let older = item(
      id: UUID(),
      title: "Older",
      updatedAt: baseDate,
      deviceID: "mac-a"
    )
    let newer = item(
      id: UUID(),
      title: "Newer",
      updatedAt: baseDate.addingTimeInterval(1),
      deviceID: "mac-a"
    )

    XCTAssertEqual(SyncResolver.merge(local: [older], remote: [newer]), [newer, older])
  }

  private func item(
    id: UUID,
    title: String,
    updatedAt: Date,
    deviceID: String,
    trashedAt: Date? = nil
  ) -> ShelfItem {
    ShelfItem(
      id: id,
      title: title,
      kind: .text,
      createdAt: baseDate,
      updatedAt: updatedAt,
      trashedAt: trashedAt,
      revision: 1,
      modifiedByDeviceID: deviceID
    )
  }
}
