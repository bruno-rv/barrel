import CloudKit
import XCTest
@testable import BarrelMac

final class CloudKitSyncServiceTests: XCTestCase {
  func testFullRecordSaveClearsAssetsForTombstone() {
    let previousFields = Set(CloudKitSyncService.assetFieldNames(assetCount: 3))
    let tombstoneFields = Set(CloudKitSyncService.assetFieldNames(assetCount: 0))

    XCTAssertEqual(CloudKitSyncService.recordSavePolicy, .allKeys)
    XCTAssertEqual(previousFields.subtracting(tombstoneFields), previousFields)
  }

  func testFullRecordSaveClearsAssetsRemovedByShrinkingAssetSet() {
    let previousFields = Set(CloudKitSyncService.assetFieldNames(assetCount: 3))
    let currentFields = Set(CloudKitSyncService.assetFieldNames(assetCount: 1))

    XCTAssertEqual(CloudKitSyncService.recordSavePolicy, .allKeys)
    XCTAssertEqual(previousFields.subtracting(currentFields), ["asset1", "asset2"])
  }
}
