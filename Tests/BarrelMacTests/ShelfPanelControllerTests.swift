import AppKit
import XCTest
@testable import BarrelMac

final class ShelfPanelControllerTests: XCTestCase {
  private let screenA = ShelfScreen(
    displayID: 1,
    frame: NSRect(x: 0, y: 0, width: 100, height: 100),
    visibleFrame: NSRect(x: 0, y: 0, width: 100, height: 90),
    isMain: true
  )
  private let screenB = ShelfScreen(
    displayID: 2,
    frame: NSRect(x: 120, y: 0, width: 100, height: 100),
    visibleFrame: NSRect(x: 120, y: 0, width: 100, height: 90),
    isMain: false
  )

  private func makeDefaults() -> UserDefaults {
    let defaults = UserDefaults(suiteName: "ShelfPanelControllerTests.\(UUID().uuidString)")!
    defaults.set(ShelfWindowPreferences.currentVersion, forKey: ShelfWindowPreferences.migrationKey)
    defaults.set(ShelfEdge.left.rawValue, forKey: ShelfWindowPreferences.edgeKey)
    defaults.set(false, forKey: ShelfWindowPreferences.autoHideKey)
    return defaults
  }

  @MainActor
  private func sendMouseMoved(to point: NSPoint) {
    let event = NSEvent.mouseEvent(
      with: .mouseMoved,
      location: point,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: 0,
      context: nil,
      eventNumber: 0,
      clickCount: 0,
      pressure: 0
    )!
    NSApplication.shared.sendEvent(event)
  }

  @MainActor
  private func sendLeftMouseUp(at point: NSPoint) {
    let event = NSEvent.mouseEvent(
      with: .leftMouseUp,
      location: point,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: 0,
      context: nil,
      eventNumber: 0,
      clickCount: 1,
      pressure: 0
    )!
    NSApplication.shared.sendEvent(event)
  }

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

  @MainActor
  func testDisablingAutoHideCancelsPendingHide() async throws {
    let defaults = makeDefaults()
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let controller = EdgeShelfController(panel: panel, defaults: defaults)
    controller.start()
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    controller.settingsDidChange()
    defaults.set(false, forKey: ShelfWindowPreferences.autoHideKey)
    controller.settingsDidChange()

    try await Task.sleep(for: .milliseconds(300))

    XCTAssertTrue(panel.frame.intersects(NSScreen.main!.frame))
    controller.stop()
  }

  @MainActor
  func testChangingEdgeImmediatelyRecomputesShownFrame() {
    let defaults = makeDefaults()
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let controller = EdgeShelfController(panel: panel, defaults: defaults)
    controller.start()
    let leftFrame = panel.frame

    defaults.set(ShelfEdge.right.rawValue, forKey: ShelfWindowPreferences.edgeKey)
    controller.settingsDidChange()

    XCTAssertNotEqual(panel.frame.origin.x, leftFrame.origin.x)
    XCTAssertEqual(panel.frame.maxX, NSScreen.main!.frame.maxX - 8)
    controller.stop()
  }

  @MainActor
  func testQueuedScreenCallbackDoesNotRepositionAfterStop() async {
    let defaults = makeDefaults()
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let controller = EdgeShelfController(panel: panel, defaults: defaults)
    controller.start()
    let sentinel = NSRect(x: 41, y: 43, width: 280, height: 480)
    panel.setFrame(sentinel, display: false)

    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )
    controller.stop()
    await Task.yield()

    XCTAssertEqual(panel.frame, sentinel)
  }

  @MainActor
  func testStoppedControllerCancelsPendingHide() async throws {
    let defaults = makeDefaults()
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let controller = EdgeShelfController(panel: panel, defaults: defaults)
    controller.start()
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    controller.settingsDidChange()
    let shownFrame = panel.frame

    controller.stop()
    try await Task.sleep(for: .milliseconds(300))

    XCTAssertEqual(panel.frame, shownFrame)
  }

  @MainActor
  func testDropTargetExitWaitsForMouseUpBeforeEndingDragLock() async throws {
    let defaults = makeDefaults()
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let controller = EdgeShelfController(panel: panel, defaults: defaults)
    controller.start()
    guard let screen = NSScreen.main else {
      return XCTFail("Expected a main screen")
    }
    let originalLocation = NSEvent.mouseLocation
    let outsidePoint = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
    CGWarpMouseCursorPosition(CGPoint(
      x: outsidePoint.x,
      y: screen.frame.maxY - outsidePoint.y
    ))
    defer {
      CGWarpMouseCursorPosition(CGPoint(
        x: originalLocation.x,
        y: screen.frame.maxY - originalLocation.y
      ))
      controller.stop()
    }

    controller.setDropTargeted(true)
    controller.setDropTargeted(false)
    try await Task.sleep(for: .milliseconds(300))

    XCTAssertTrue(panel.frame.intersects(screen.frame))

    sendLeftMouseUp(at: outsidePoint)
    try await Task.sleep(for: .milliseconds(300))

    XCTAssertFalse(panel.frame.intersects(screen.frame))
  }

  @MainActor
  func testStoppingDuringDragClearsLockBeforeRestart() {
    let defaults = makeDefaults()
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let controller = EdgeShelfController(panel: panel, defaults: defaults)
    controller.start()
    guard let screen = NSScreen.main else {
      return XCTFail("Expected a main screen")
    }
    let originalLocation = NSEvent.mouseLocation
    let outsidePoint = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
    CGWarpMouseCursorPosition(CGPoint(
      x: outsidePoint.x,
      y: screen.frame.maxY - outsidePoint.y
    ))
    defer {
      CGWarpMouseCursorPosition(CGPoint(
        x: originalLocation.x,
        y: screen.frame.maxY - originalLocation.y
      ))
      controller.stop()
    }

    controller.setDropTargeted(true)
    controller.stop()
    controller.start()

    XCTAssertFalse(panel.frame.intersects(screen.frame))
  }

  @MainActor
  func testUnrelatedDefaultsChangeDoesNotStrandPendingReveal() async throws {
    let defaults = makeDefaults()
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let controller = EdgeShelfController(panel: panel, defaults: defaults)
    controller.start()
    guard let screen = NSScreen.main else {
      return XCTFail("Expected a main screen")
    }
    let originalLocation = NSEvent.mouseLocation
    let edgePoint = NSPoint(x: screen.frame.minX + 1, y: screen.frame.midY)
    CGWarpMouseCursorPosition(CGPoint(x: edgePoint.x, y: screen.frame.maxY - edgePoint.y))
    defer {
      CGWarpMouseCursorPosition(CGPoint(
        x: originalLocation.x,
        y: screen.frame.maxY - originalLocation.y
      ))
      controller.stop()
    }
    sendMouseMoved(to: edgePoint)
    defaults.set(true, forKey: "UnrelatedShelfPreference")
    controller.settingsDidChange()

    try await Task.sleep(for: .milliseconds(150))

    XCTAssertTrue(panel.frame.intersects(screen.frame))
  }

  @MainActor
  func testEdgeOnlyChangeDoesNotStrandPendingHide() async throws {
    let defaults = makeDefaults()
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let controller = EdgeShelfController(panel: panel, defaults: defaults)
    controller.start()
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    controller.settingsDidChange()
    defaults.set(ShelfEdge.right.rawValue, forKey: ShelfWindowPreferences.edgeKey)
    controller.settingsDidChange()

    try await Task.sleep(for: .milliseconds(300))

    XCTAssertFalse(panel.frame.intersects(NSScreen.main!.frame))
    controller.stop()
  }

  func testScreenResolverUsesPointerScreenBeforeTrackedScreen() {
    let resolved = ShelfScreenResolver.resolve(
      point: NSPoint(x: 150, y: 50),
      trackedDisplayID: screenA.displayID,
      screens: [screenA, screenB]
    )

    XCTAssertEqual(resolved?.displayID, screenB.displayID)
  }

  func testScreenResolverUsesTrackedScreenWhenPointerIsInGap() {
    let resolved = ShelfScreenResolver.resolve(
      point: NSPoint(x: 110, y: 50),
      trackedDisplayID: screenB.displayID,
      screens: [screenA, screenB]
    )

    XCTAssertEqual(resolved?.displayID, screenB.displayID)
  }

  func testScreenResolverUsesMainWhenTrackedScreenDisappears() {
    let resolved = ShelfScreenResolver.resolve(
      point: NSPoint(x: 110, y: 50),
      trackedDisplayID: screenB.displayID,
      screens: [screenA]
    )

    XCTAssertEqual(resolved?.displayID, screenA.displayID)
  }

  func testScreenResolverUsesFirstWhenThereIsNoMainScreen() {
    let first = ShelfScreen(
      displayID: 3,
      frame: screenA.frame,
      visibleFrame: screenA.visibleFrame,
      isMain: false
    )

    let resolved = ShelfScreenResolver.resolve(
      point: NSPoint(x: 110, y: 50),
      trackedDisplayID: nil,
      screens: [first, screenB]
    )

    XCTAssertEqual(resolved?.displayID, first.displayID)
  }

  @MainActor
  func testExplicitRevealUsesResolverAndTracksResolvedDisplay() {
    let defaults = makeDefaults()
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    var resolvedPoints: [NSPoint] = []
    let controller = EdgeShelfController(
      panel: panel,
      defaults: defaults,
      mouseLocation: { NSPoint(x: 110, y: 50) },
      screens: { [self.screenA, self.screenB] },
      resolveScreen: { point, trackedDisplayID, screens in
        resolvedPoints.append(point)
        return screens.first(where: { $0.displayID == self.screenB.displayID })
      }
    )

    controller.showExplicitly()

    XCTAssertEqual(resolvedPoints, [NSPoint(x: 110, y: 50)])
    XCTAssertEqual(controller.trackedDisplayID, screenB.displayID)
  }

  @MainActor
  func testMovingFromHidePendingShelfToOtherDisplayEdgeShowsShelfThere() async throws {
    let defaults = makeDefaults()
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let screenA = ShelfScreen(
      displayID: 1,
      frame: NSRect(x: 0, y: 0, width: 600, height: 700),
      visibleFrame: NSRect(x: 0, y: 0, width: 600, height: 680),
      isMain: true
    )
    let screenB = ShelfScreen(
      displayID: 2,
      frame: NSRect(x: 720, y: 0, width: 600, height: 700),
      visibleFrame: NSRect(x: 720, y: 0, width: 600, height: 680),
      isMain: false
    )
    var point = NSPoint(x: screenA.frame.midX, y: screenA.frame.midY)
    let controller = EdgeShelfController(
      panel: panel,
      defaults: defaults,
      mouseLocation: { point },
      screens: { [screenA, screenB] }
    )
    controller.start()
    defer { controller.stop() }
    controller.showExplicitly()
    let layout = ShelfPanelLayout()
    let shownOnB = layout.targetFrame(
      shown: true,
      edge: .left,
      display: ShelfDisplayGeometry(frame: screenB.frame, visibleFrame: screenB.visibleFrame)
    )

    point = NSPoint(x: screenA.frame.maxX - 1, y: screenA.frame.midY)
    sendMouseMoved(to: point)
    point = NSPoint(x: screenB.frame.minX + 1, y: screenB.frame.midY)
    sendMouseMoved(to: point)

    XCTAssertEqual(panel.frame, shownOnB)
    XCTAssertTrue(panel.isVisible)
    XCTAssertEqual(controller.trackedDisplayID, screenB.displayID)

    try await Task.sleep(for: .milliseconds(300))

    XCTAssertEqual(panel.frame, shownOnB)
    XCTAssertTrue(panel.isVisible)
  }

  @MainActor
  func testMovingDragLockedShelfToOtherDisplayRepositionsItShown() {
    let defaults = makeDefaults()
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let screenA = ShelfScreen(
      displayID: 1,
      frame: NSRect(x: 0, y: 0, width: 600, height: 700),
      visibleFrame: NSRect(x: 0, y: 0, width: 600, height: 680),
      isMain: true
    )
    let screenB = ShelfScreen(
      displayID: 2,
      frame: NSRect(x: 720, y: 0, width: 600, height: 700),
      visibleFrame: NSRect(x: 720, y: 0, width: 600, height: 680),
      isMain: false
    )
    var point = NSPoint(x: screenA.frame.midX, y: screenA.frame.midY)
    let controller = EdgeShelfController(
      panel: panel,
      defaults: defaults,
      mouseLocation: { point },
      screens: { [screenA, screenB] }
    )
    controller.start()
    defer { controller.stop() }
    controller.showExplicitly()
    controller.setDropTargeted(true)

    point = NSPoint(x: screenB.frame.midX, y: screenB.frame.midY)
    sendMouseMoved(to: point)

    let shownOnB = ShelfPanelLayout().targetFrame(
      shown: true,
      edge: .left,
      display: ShelfDisplayGeometry(frame: screenB.frame, visibleFrame: screenB.visibleFrame)
    )
    XCTAssertEqual(panel.frame, shownOnB)
    XCTAssertTrue(panel.isVisible)
    XCTAssertEqual(controller.trackedDisplayID, screenB.displayID)
  }
}
