import AppKit
import XCTest
@testable import BarrelMac

final class EdgeShelfModelTests: XCTestCase {
  private let display = ShelfDisplayGeometry(
    frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
    visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1055)
  )

  func testEdgeEntrySchedulesRevealAndElapsedDelayShowsPanel() {
    var machine = EdgeShelfStateMachine()

    XCTAssertEqual(machine.handle(.edgeEntered), [.scheduleReveal])
    XCTAssertEqual(machine.phase, .revealPending)
    XCTAssertEqual(machine.handle(.revealDelayElapsed), [.show])
    XCTAssertEqual(machine.phase, .shown)
  }

  func testLeavingBeforeRevealCancelsPendingReveal() {
    var machine = EdgeShelfStateMachine()
    _ = machine.handle(.edgeEntered)

    XCTAssertEqual(machine.handle(.edgeExited), [.cancelReveal])
    XCTAssertEqual(machine.phase, .hidden)
  }

  func testPointerExitSchedulesHideAndElapsedDelayHidesPanel() {
    var machine = EdgeShelfStateMachine(phase: .shown)

    XCTAssertEqual(machine.handle(.pointerExitedPanel), [.scheduleHide])
    XCTAssertEqual(machine.phase, .hidePending)
    XCTAssertEqual(machine.handle(.hideDelayElapsed), [.hide])
    XCTAssertEqual(machine.phase, .hidden)
  }

  func testEnteringPanelBeforeHideCancelsPendingHide() {
    var machine = EdgeShelfStateMachine(phase: .hidePending)

    XCTAssertEqual(machine.handle(.pointerEnteredPanel), [.cancelHide])
    XCTAssertEqual(machine.phase, .shown)
  }

  func testDragKeepsShownShelfOpenUntilMouseUpOutside() {
    var machine = EdgeShelfStateMachine(phase: .shown)

    XCTAssertEqual(machine.handle(.dragBegan), [.cancelHide])
    XCTAssertEqual(machine.phase, .dragLocked)
    XCTAssertEqual(
      machine.handle(.dragEnded(pointerInside: false)),
      [.scheduleHide]
    )
    XCTAssertEqual(machine.phase, .hidePending)
    XCTAssertEqual(machine.handle(.hideDelayElapsed), [.hide])
  }

  func testMouseUpInsideUnlocksDragWithoutSchedulingHide() {
    var machine = EdgeShelfStateMachine(phase: .dragLocked)

    XCTAssertEqual(machine.handle(.dragEnded(pointerInside: true)), [])
    XCTAssertEqual(machine.phase, .shown)
  }

  func testExplicitShowCancelsPendingDelayedWork() {
    var revealPending = EdgeShelfStateMachine(phase: .revealPending)
    var hidePending = EdgeShelfStateMachine(phase: .hidePending)

    XCTAssertEqual(revealPending.handle(.explicitShow), [.cancelReveal, .show])
    XCTAssertEqual(revealPending.phase, .shown)
    XCTAssertEqual(hidePending.handle(.explicitShow), [.cancelHide, .show])
    XCTAssertEqual(hidePending.phase, .shown)
  }

  func testDisablingAutoHideShowsPanelAndCancelsPendingWork() {
    var hidden = EdgeShelfStateMachine()
    var revealPending = EdgeShelfStateMachine(phase: .revealPending)
    var hidePending = EdgeShelfStateMachine(phase: .hidePending)

    XCTAssertEqual(
      hidden.handle(.autoHideChanged(isEnabled: false, pointerInside: false)),
      [.show]
    )
    XCTAssertEqual(hidden.phase, .shown)
    XCTAssertEqual(
      revealPending.handle(.autoHideChanged(isEnabled: false, pointerInside: false)),
      [.cancelReveal, .show]
    )
    XCTAssertEqual(
      hidePending.handle(.autoHideChanged(isEnabled: false, pointerInside: true)),
      [.cancelHide, .show]
    )
  }

  func testEnablingAutoHideOnlySchedulesHideWhenPointerIsOutside() {
    var outside = EdgeShelfStateMachine(phase: .shown)
    var inside = EdgeShelfStateMachine(phase: .shown)

    XCTAssertEqual(
      outside.handle(.autoHideChanged(isEnabled: true, pointerInside: false)),
      [.scheduleHide]
    )
    XCTAssertEqual(outside.phase, .hidePending)
    XCTAssertEqual(
      inside.handle(.autoHideChanged(isEnabled: true, pointerInside: true)),
      []
    )
    XCTAssertEqual(inside.phase, .shown)
  }

  func testEventThatDoesNotApplyIsIdempotent() {
    var machine = EdgeShelfStateMachine()

    XCTAssertEqual(machine.handle(.hideDelayElapsed), [])
    XCTAssertEqual(machine.phase, .hidden)
  }

  func testShownLeftFrameIsInsetAndCenteredInVisibleFrame() {
    let frame = ShelfPanelLayout().targetFrame(
      shown: true,
      edge: .left,
      display: display
    )

    XCTAssertEqual(frame, NSRect(x: 8, y: 287.5, width: 280, height: 480))
  }

  func testHiddenLeftFrameIsCompletelyOffscreen() {
    let frame = ShelfPanelLayout().targetFrame(
      shown: false,
      edge: .left,
      display: display
    )

    XCTAssertEqual(frame.size, NSSize(width: 280, height: 480))
    XCTAssertEqual(frame.maxX, display.frame.minX)
  }

  func testRightEdgeFramesMirrorHorizontalPlacement() {
    let layout = ShelfPanelLayout()

    let shown = layout.targetFrame(shown: true, edge: .right, display: display)
    let hidden = layout.targetFrame(shown: false, edge: .right, display: display)

    XCTAssertEqual(shown, NSRect(x: 1632, y: 287.5, width: 280, height: 480))
    XCTAssertEqual(hidden.minX, display.frame.maxX)
    XCTAssertEqual(hidden.size, layout.panelSize)
  }

  func testVerticalPlacementClampsToTwelvePointMargin() {
    let shortDisplay = ShelfDisplayGeometry(
      frame: NSRect(x: 0, y: 0, width: 1920, height: 500),
      visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 470)
    )

    let frame = ShelfPanelLayout().targetFrame(
      shown: true,
      edge: .left,
      display: shortDisplay
    )

    XCTAssertEqual(frame.minY, shortDisplay.visibleFrame.minY + 12)
  }

  func testActivationZoneUsesFullDisplayFrame() {
    let layout = ShelfPanelLayout()
    let pointAboveVisibleFrame = NSPoint(x: 1, y: 1070)

    XCTAssertTrue(layout.isActivationPoint(
      pointAboveVisibleFrame,
      edge: .left,
      display: display
    ))
    XCTAssertFalse(layout.isActivationPoint(
      NSPoint(x: 4, y: 1070),
      edge: .left,
      display: display
    ))
    XCTAssertTrue(layout.isActivationPoint(
      NSPoint(x: 1919, y: 1070),
      edge: .right,
      display: display
    ))
  }
}
