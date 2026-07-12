import Foundation
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

  func testLegacyManifestRewritesAsLocalStateEnvelope() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("ShelfItemTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let manifestURL = root.appendingPathComponent("shelf.json")
    let legacy = Data(#"[{"id":"60D1B05E-40A3-433D-9B25-587EB5E35C51","title":"Brief","kind":"file","createdAt":"2026-07-10T10:00:00Z","updatedAt":"2026-07-10T10:00:00Z","fileName":"Brief.pdf","relativePath":null,"text":null,"children":[]}]"#.utf8)
    try legacy.write(to: manifestURL)
    let repository = ShelfRepository(
      configuration: RepositoryConfiguration(rootURL: root, deviceID: "test-mac")
    )

    let loaded = try await repository.load()

    XCTAssertEqual(loaded.map(\.title), ["Brief"])
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
    )
    XCTAssertEqual((object["items"] as? [[String: Any]])?.count, 1)
    XCTAssertEqual((object["history"] as? [[String: Any]])?.count, 0)
    XCTAssertEqual(object["exportedItemIDs"] as? [String], [])
  }
}
