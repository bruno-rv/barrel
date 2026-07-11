import AppKit
import XCTest
@testable import BarrelMac

final class ShelfPanelControllerTests: XCTestCase {
  @MainActor
  func testPanelIsNonActivatingAndAvailableInFullScreenSpaces() {
    let panel = ShelfPanelController.makePanel(contentView: NSView())

    XCTAssertTrue(panel.styleMask.contains(.borderless))
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertEqual(panel.level, .statusBar)
    XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
    XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
    XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
    XCTAssertFalse(panel.hidesOnDeactivate)
    XCTAssertEqual(panel.contentView?.frame.size, NSSize(width: 280, height: 480))
  }

  @MainActor
  func testPanelCanBecomeKeyButNotMain() {
    let panel = ShelfPanelController.makePanel(contentView: NSView())

    XCTAssertTrue(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
  }
}
