import XCTest
@testable import BarrelCore

final class ShelfItemTests: XCTestCase {
  func testLegacyManifestDecodesNewFieldsWithSafeDefaults() throws {
    let data = Data(#"{"id":"60D1B05E-40A3-433D-9B25-587EB5E35C51","title":"Brief","kind":"file","createdAt":"2026-07-10T10:00:00Z","updatedAt":"2026-07-10T10:00:00Z","fileName":"Brief.pdf","relativePath":"Items/1/Brief.pdf","text":null,"children":[]}"#.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let item = try decoder.decode(ShelfItem.self, from: data)

    XCTAssertEqual(item.origin, .imported)
    XCTAssertNil(item.expiresAt)
    XCTAssertFalse(item.isPinned)
    XCTAssertNil(item.trashedAt)
    XCTAssertEqual(item.revision, 0)
    XCTAssertEqual(item.modifiedByDeviceID, "")
  }

  func testFiltersExcludeTrashUnlessTrashIsSelected() {
    let liveFile = ShelfItem(title: "Live", kind: .file)
    let trashedFile = ShelfItem(title: "Trash", kind: .file, trashedAt: .now)

    XCTAssertTrue(ShelfFilter.files.accepts(liveFile))
    XCTAssertFalse(ShelfFilter.files.accepts(trashedFile))
    XCTAssertFalse(ShelfFilter.trash.accepts(liveFile))
    XCTAssertTrue(ShelfFilter.trash.accepts(trashedFile))
  }
}
