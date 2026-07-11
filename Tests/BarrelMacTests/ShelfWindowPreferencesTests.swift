import XCTest
@testable import BarrelMac

final class ShelfWindowPreferencesTests: XCTestCase {
  private func isolatedDefaults() -> UserDefaults {
    let suiteName = "ShelfWindowPreferencesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    addTeardownBlock {
      defaults.removePersistentDomain(forName: suiteName)
    }
    return defaults
  }

  func testFirstMigrationSetsRecommendedBehavior() {
    let defaults = isolatedDefaults()
    defaults.set("right", forKey: ShelfWindowPreferences.edgeKey)
    defaults.set(false, forKey: ShelfWindowPreferences.autoHideKey)

    ShelfWindowPreferences.migrate(defaults)

    XCTAssertEqual(
      defaults.string(forKey: ShelfWindowPreferences.edgeKey),
      "left"
    )
    XCTAssertTrue(defaults.bool(forKey: ShelfWindowPreferences.autoHideKey))
    XCTAssertEqual(
      defaults.integer(forKey: ShelfWindowPreferences.migrationKey),
      ShelfWindowPreferences.currentVersion
    )
  }

  func testCompletedMigrationPreservesLaterUserChoices() {
    let defaults = isolatedDefaults()
    ShelfWindowPreferences.migrate(defaults)
    defaults.set("right", forKey: ShelfWindowPreferences.edgeKey)
    defaults.set(false, forKey: ShelfWindowPreferences.autoHideKey)

    ShelfWindowPreferences.migrate(defaults)

    XCTAssertEqual(
      defaults.string(forKey: ShelfWindowPreferences.edgeKey),
      "right"
    )
    XCTAssertFalse(defaults.bool(forKey: ShelfWindowPreferences.autoHideKey))
  }
}
