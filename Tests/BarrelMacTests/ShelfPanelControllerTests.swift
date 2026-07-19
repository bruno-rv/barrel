import AppKit
import XCTest
@testable import BarrelMac

@MainActor
private final class TestEdgeShelfScheduledTask: EdgeShelfScheduledTask {
  var isCancelled = false

  func cancel() {
    isCancelled = true
  }
}

@MainActor
private final class TestEdgeShelfScheduler: EdgeShelfScheduler {
  private struct Scheduled {
    let deadline: TimeInterval
    let task: TestEdgeShelfScheduledTask
    let action: @MainActor () -> Void
  }

  private var now: TimeInterval = 0
  private var scheduled: [Scheduled] = []
  var pendingTaskCount: Int { scheduled.filter { !$0.task.isCancelled }.count }

  func schedule(
    after delay: TimeInterval,
    _ action: @escaping @MainActor () -> Void
  ) -> any EdgeShelfScheduledTask {
    let task = TestEdgeShelfScheduledTask()
    scheduled.append(Scheduled(deadline: now + delay, task: task, action: action))
    return task
  }

  func advance(by interval: TimeInterval) {
    now += interval
    while let index = scheduled.indices
      .filter({ scheduled[$0].deadline <= now })
      .min(by: { scheduled[$0].deadline < scheduled[$1].deadline }) {
      let item = scheduled.remove(at: index)
      if !item.task.isCancelled { item.action() }
    }
  }
}

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
    XCTAssertEqual(panel.level, ShelfPanelController.shelfWindowLevel)
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
  func testEdgeRevealIsInstantAndHideWaitsThreeSecondsAfterExit() {
    let defaults = makeDefaults()
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let screen = ShelfScreen(
      displayID: 1,
      frame: NSRect(x: 0, y: 0, width: 600, height: 700),
      visibleFrame: NSRect(x: 0, y: 0, width: 600, height: 680),
      isMain: true
    )
    let scheduler = TestEdgeShelfScheduler()
    var point = NSPoint(x: screen.frame.minX + 1, y: screen.frame.midY)
    let controller = EdgeShelfController(
      panel: panel,
      defaults: defaults,
      mouseLocation: { point },
      screens: { [screen] },
      scheduler: scheduler
    )
    controller.start()
    defer { controller.stop() }

    sendMouseMoved(to: point)
    // Instant: no dwell required on the extreme edge.
    XCTAssertTrue(panel.frame.intersects(screen.frame))
    // Staying on the activation strip must not start hide.
    scheduler.advance(by: 3.0)
    XCTAssertTrue(panel.frame.intersects(screen.frame))

    // Leave the shelf; hide only after the full 3s exit delay.
    point = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
    sendMouseMoved(to: point)
    scheduler.advance(by: 2.999)
    XCTAssertTrue(panel.frame.intersects(screen.frame))
    scheduler.advance(by: 0.001)
    XCTAssertFalse(panel.frame.intersects(screen.frame))
  }

  @MainActor
  func testDragLockPreventsHideUntilMouseUpOutside() {
    let defaults = makeDefaults()
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let scheduler = TestEdgeShelfScheduler()
    let controller = EdgeShelfController(panel: panel, defaults: defaults, scheduler: scheduler)
    controller.start()
    controller.showExplicitly()
    controller.setDropTargeted(true)

    scheduler.advance(by: 3.0)

    XCTAssertTrue(panel.frame.intersects(NSScreen.main!.frame))
    controller.stop()
  }

  @MainActor
  func testAutoHideToggleDuringDragStillWaitsThreeSecondsAfterMouseUpOutside() {
    let defaults = makeDefaults()
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let scheduler = TestEdgeShelfScheduler()
    guard let screen = NSScreen.main else {
      return XCTFail("Expected a main screen")
    }
    let outsidePoint = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
    let controller = EdgeShelfController(
      panel: panel,
      defaults: defaults,
      mouseLocation: { outsidePoint },
      scheduler: scheduler
    )
    controller.start()
    defer { controller.stop() }
    controller.showExplicitly()
    controller.setDropTargeted(true)

    defaults.set(false, forKey: ShelfWindowPreferences.autoHideKey)
    controller.settingsDidChange()
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    controller.settingsDidChange()
    sendLeftMouseUp(at: outsidePoint)

    scheduler.advance(by: 2.999)
    XCTAssertTrue(panel.frame.intersects(screen.frame))
    scheduler.advance(by: 0.001)
    XCTAssertFalse(panel.frame.intersects(screen.frame))
  }

  @MainActor
  func testExplicitShowDuringDragStillWaitsThreeSecondsAfterMouseUpOutside() {
    let defaults = makeDefaults()
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let scheduler = TestEdgeShelfScheduler()
    guard let screen = NSScreen.main else {
      return XCTFail("Expected a main screen")
    }
    let outsidePoint = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
    let controller = EdgeShelfController(
      panel: panel,
      defaults: defaults,
      mouseLocation: { outsidePoint },
      scheduler: scheduler
    )
    controller.start()
    defer { controller.stop() }
    controller.showExplicitly()
    controller.setDropTargeted(true)
    scheduler.advance(by: 3.0)

    controller.showExplicitly()
    sendLeftMouseUp(at: outsidePoint)

    scheduler.advance(by: 2.999)
    XCTAssertTrue(panel.frame.intersects(screen.frame))
    scheduler.advance(by: 0.001)
    XCTAssertFalse(panel.frame.intersects(screen.frame))
  }

  @MainActor
  func testStopCancelsEveryPendingTask() {
    let defaults = makeDefaults()
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let scheduler = TestEdgeShelfScheduler()
    let screen = ShelfScreen(
      displayID: 1,
      frame: NSRect(x: 0, y: 0, width: 600, height: 700),
      visibleFrame: NSRect(x: 0, y: 0, width: 600, height: 680),
      isMain: true
    )
    var point = NSPoint(x: screen.frame.minX + 1, y: screen.frame.midY)
    let controller = EdgeShelfController(
      panel: panel,
      defaults: defaults,
      mouseLocation: { point },
      screens: { [screen] },
      scheduler: scheduler
    )
    controller.start()
    sendMouseMoved(to: point)
    // Leave the panel so a hide task is scheduled, then stop cancels it.
    point = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
    sendMouseMoved(to: point)
    XCTAssertEqual(scheduler.pendingTaskCount, 1)

    controller.stop()

    XCTAssertEqual(scheduler.pendingTaskCount, 0)
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
  func testReenablingAutoHideOutsideWaitsThreeSecondsBeforeHiding() {
    let defaults = makeDefaults()
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let screen = ShelfScreen(
      displayID: 1,
      frame: NSRect(x: 0, y: 0, width: 600, height: 700),
      visibleFrame: NSRect(x: 0, y: 0, width: 600, height: 680),
      isMain: true
    )
    let scheduler = TestEdgeShelfScheduler()
    let point = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
    let controller = EdgeShelfController(
      panel: panel,
      defaults: defaults,
      mouseLocation: { point },
      screens: { [screen] },
      scheduler: scheduler
    )
    controller.start()
    defer { controller.stop() }

    XCTAssertTrue(panel.frame.intersects(screen.frame))
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    controller.settingsDidChange()

    scheduler.advance(by: 2.999)
    XCTAssertTrue(panel.frame.intersects(screen.frame))
    scheduler.advance(by: 0.001)
    XCTAssertFalse(panel.frame.intersects(screen.frame))
  }

  @MainActor
  func testTogglingAutoHideOutsideRestartsThreeSecondHideDelay() {
    let defaults = makeDefaults()
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let screen = ShelfScreen(
      displayID: 1,
      frame: NSRect(x: 0, y: 0, width: 600, height: 700),
      visibleFrame: NSRect(x: 0, y: 0, width: 600, height: 680),
      isMain: true
    )
    let scheduler = TestEdgeShelfScheduler()
    let point = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
    let controller = EdgeShelfController(
      panel: panel,
      defaults: defaults,
      mouseLocation: { point },
      screens: { [screen] },
      scheduler: scheduler
    )
    controller.start()
    defer { controller.stop() }
    controller.showExplicitly()
    sendMouseMoved(to: point)
    scheduler.advance(by: 1.0)

    defaults.set(false, forKey: ShelfWindowPreferences.autoHideKey)
    controller.settingsDidChange()
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    controller.settingsDidChange()

    scheduler.advance(by: 2.999)
    XCTAssertTrue(panel.frame.intersects(screen.frame))
    scheduler.advance(by: 0.001)
    XCTAssertFalse(panel.frame.intersects(screen.frame))
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
  func testDropTargetExitWaitsForMouseUpBeforeEndingDragLock() {
    let defaults = makeDefaults()
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let scheduler = TestEdgeShelfScheduler()
    let controller = EdgeShelfController(panel: panel, defaults: defaults, scheduler: scheduler)
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
    scheduler.advance(by: 3.0)

    XCTAssertTrue(panel.frame.intersects(screen.frame))

    sendLeftMouseUp(at: outsidePoint)

    scheduler.advance(by: 2.999)
    XCTAssertTrue(panel.frame.intersects(screen.frame))
    scheduler.advance(by: 0.001)
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
  func testUnrelatedDefaultsChangeDoesNotStrandPendingReveal() {
    let defaults = makeDefaults()
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let scheduler = TestEdgeShelfScheduler()
    let screen = ShelfScreen(
      displayID: 1,
      frame: NSRect(x: 0, y: 0, width: 600, height: 700),
      visibleFrame: NSRect(x: 0, y: 0, width: 600, height: 680),
      isMain: true
    )
    let edgePoint = NSPoint(x: screen.frame.minX + 1, y: screen.frame.midY)
    let controller = EdgeShelfController(
      panel: panel,
      defaults: defaults,
      mouseLocation: { edgePoint },
      screens: { [screen] },
      scheduler: scheduler
    )
    controller.start()
    defer { controller.stop() }

    sendMouseMoved(to: edgePoint)
    defaults.set(true, forKey: "UnrelatedShelfPreference")
    controller.settingsDidChange()

    XCTAssertTrue(panel.frame.intersects(screen.frame))
  }

  @MainActor
  func testEdgeOnlyChangeDoesNotStrandPendingHide() {
    let defaults = makeDefaults()
    let panel = ShelfPanelController.makePanel(contentView: NSView())
    let scheduler = TestEdgeShelfScheduler()
    let controller = EdgeShelfController(panel: panel, defaults: defaults, scheduler: scheduler)
    controller.start()
    defaults.set(true, forKey: ShelfWindowPreferences.autoHideKey)
    controller.settingsDidChange()
    defaults.set(ShelfEdge.right.rawValue, forKey: ShelfWindowPreferences.edgeKey)
    controller.settingsDidChange()

    scheduler.advance(by: 3.0)

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
