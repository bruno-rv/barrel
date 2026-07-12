import AppKit
import Testing
@testable import BarrelMac

@MainActor
private final class ActivationSpy: QuickSendActivating {
  var activationCount = 0
  func activate() { activationCount += 1 }
}

@MainActor
private final class FocusSchedulerSpy: QuickSendFocusScheduling {
  var lastResponder: NSResponder?
  func scheduleFocus(_ responder: NSResponder, in window: NSWindow) {
    lastResponder = responder
  }
}

private struct EmptyFinderReader: FinderSelectionReading {
  func readSelection() async -> FinderSelectionState { .empty }
}

@MainActor
struct QuickSendPanelControllerTests {
  private func makeModel(
    running: Bool = false,
    dismiss: @escaping () -> Void = {}
  ) -> QuickSendModel {
    let model = QuickSendModel(
      finderReader: EmptyFinderReader(), items: { [] }, history: { [] }, destinations: { [] },
      isUndoEligible: { _ in false }, performPrimary: { _ in }, dismiss: dismiss
    )
    model.isOperationRunning = running
    return model
  }

  @Test func panelIsActivatingKeyCapableAndNotMain() {
    let panel = QuickSendPanelController.makePanel(contentView: NSView())

    #expect(panel.canBecomeKey)
    #expect(!panel.canBecomeMain)
    #expect(!panel.styleMask.contains(.nonactivatingPanel))
  }

  @Test func showReusesPanelActivatesEveryTimeCentersOnPointerScreenAndSchedulesFocus() {
    let activation = ActivationSpy()
    let focus = FocusSchedulerSpy()
    let panel = QuickSendPanelController.makePanel(contentView: NSView())
    let searchField = NSSearchField()
    let controller = QuickSendPanelController(
      model: makeModel(), panel: panel, activator: activation, focusScheduler: focus,
      mouseLocation: { NSPoint(x: 900, y: 300) },
      screenFrames: {
        [NSRect(x: 0, y: 0, width: 500, height: 500),
         NSRect(x: 500, y: 0, width: 800, height: 600)]
      }
    )
    controller.registerSearchField(searchField)

    controller.show()
    let firstPanel = controller.panelForTesting
    controller.show()

    #expect(controller.panelForTesting === firstPanel)
    #expect(activation.activationCount == 2)
    #expect(focus.lastResponder === searchField)
    #expect(panel.frame.midX == 900)
    #expect(panel.frame.midY == 300)
    panel.orderOut(nil)
  }

  @Test func escapeClosesSecondaryLayerBeforeOrderingOutPanel() async {
    var dismissalCount = 0
    let model = makeModel(dismiss: { dismissalCount += 1 })
    let controller = QuickSendPanelController(model: model)

    #expect(controller.handleEscape())
    #expect(dismissalCount == 1)
  }

  @Test func resignKeyDismissesOnlyWhileIdle() {
    let idlePanel = QuickSendPanelController.makePanel(contentView: NSView())
    let idle = QuickSendPanelController(model: makeModel(), panel: idlePanel)
    idlePanel.orderFront(nil)
    idle.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
    #expect(!idlePanel.isVisible)

    let busyPanel = QuickSendPanelController.makePanel(contentView: NSView())
    let busy = QuickSendPanelController(model: makeModel(running: true), panel: busyPanel)
    busyPanel.orderFront(nil)
    busy.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
    #expect(busyPanel.isVisible)
    busyPanel.orderOut(nil)
  }
}
