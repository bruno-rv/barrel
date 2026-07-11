import XCTest
@testable import BarrelCore

final class SearchTests: XCTestCase {
  func testSearchMatchesNestedStackChildren() {
    let child = ShelfItem(title: "Needle", kind: .text, text: "nested result")
    let stack = ShelfItem(title: "Documents", kind: .stack, children: [child])

    XCTAssertEqual(ShelfFilter.all.filter([stack], query: "needle"), [stack])
  }

  func testNormalFiltersExcludeTrash() {
    let live = ShelfItem(title: "Live", kind: .file)
    let trashed = ShelfItem(title: "Deleted", kind: .file, trashedAt: .now)

    XCTAssertEqual(ShelfFilter.files.filter([trashed, live], query: ""), [live])
  }

  func testTrashAppearsOnlyInTrashFilter() {
    let live = ShelfItem(title: "Live", kind: .text)
    let trashed = ShelfItem(title: "Deleted", kind: .text, trashedAt: .now)

    XCTAssertEqual(ShelfFilter.all.filter([live, trashed], query: ""), [live])
    XCTAssertEqual(ShelfFilter.trash.filter([live, trashed], query: ""), [trashed])
  }
}
