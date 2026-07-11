import XCTest
@testable import BarrelCore

final class RetentionPolicyTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testDefaultExpirationDependsOnOrigin() {
    let policy = RetentionPolicy()

    XCTAssertNil(policy.expirationDate(for: .imported, now: now))
    XCTAssertEqual(
      policy.expirationDate(for: .clipboard, now: now),
      now.addingTimeInterval(86_400)
    )
  }

  func testExpirationPresetsProduceExpectedDates() {
    XCTAssertEqual(ShelfExpirationPreset.oneHour.expirationDate(from: now), now.addingTimeInterval(3_600))
    XCTAssertEqual(ShelfExpirationPreset.oneDay.expirationDate(from: now), now.addingTimeInterval(86_400))
    XCTAssertEqual(ShelfExpirationPreset.oneWeek.expirationDate(from: now), now.addingTimeInterval(604_800))
    XCTAssertNil(ShelfExpirationPreset.never.expirationDate(from: now))
  }

  func testPinnedItemDoesNotExpire() {
    let item = ShelfItem(
      title: "Pinned",
      kind: .text,
      expiresAt: now.addingTimeInterval(-1),
      isPinned: true
    )

    XCTAssertFalse(item.isExpired(at: now))
  }

  func testCleanupRemovesExpiredThenOldestClipboardButNeverImportedForQuota() {
    let expiredID = UUID()
    let oldestClipboardID = UUID()
    let importedID = UUID()
    let items = [
      ShelfItem(
        id: importedID,
        title: "Deliberate import",
        kind: .file,
        createdAt: now.addingTimeInterval(-300),
        updatedAt: now,
        origin: .imported
      ),
      ShelfItem(
        id: oldestClipboardID,
        title: "Old clipboard",
        kind: .text,
        createdAt: now.addingTimeInterval(-200),
        updatedAt: now,
        origin: .clipboard
      ),
      ShelfItem(
        id: expiredID,
        title: "Expired",
        kind: .text,
        createdAt: now.addingTimeInterval(-100),
        updatedAt: now,
        origin: .imported,
        expiresAt: now.addingTimeInterval(-1)
      )
    ]
    let sizes = [importedID: Int64(80), oldestClipboardID: Int64(30), expiredID: Int64(10)]

    let candidates = RetentionPolicy().cleanupCandidates(
      items: items,
      now: now,
      bytesByItemID: sizes,
      quotaBytes: 100
    )

    XCTAssertEqual(candidates, [expiredID, oldestClipboardID])
    XCTAssertFalse(candidates.contains(importedID))
  }
}
