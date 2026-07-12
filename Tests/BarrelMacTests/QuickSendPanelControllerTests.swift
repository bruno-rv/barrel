import AppKit
import BarrelCore
import Testing
@testable import BarrelMac

@MainActor
private final class ActivationSpy: QuickSendActivating {
  var activationCount = 0
  var onActivate: () -> Void = {}
  func activate() {
    activationCount += 1
    onActivate()
  }
}

@MainActor
private final class FocusSchedulerSpy: QuickSendFocusScheduling {
  var lastResponder: NSResponder?
  var focusCount = 0
  func scheduleFocus(_ responder: NSResponder, in window: NSWindow) {
    lastResponder = responder
    focusCount += 1
  }
}

private struct EmptyFinderReader: FinderSelectionReading {
  func readSelection(context: FinderSelectionContext) async -> FinderSelectionState { .empty }
}

private final class FinderExecutionSpy: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func execute() -> FinderAppleEventResult {
    lock.withLock { count += 1 }
    let list = NSAppleEventDescriptor.list()
    list.insert(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: "/tmp/Selected.txt")), at: 1)
    return .descriptor(list)
  }

  var callCount: Int { lock.withLock { count } }
}

private final class CountingFinderReader: FinderSelectionReading, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  let state: FinderSelectionState

  init(state: FinderSelectionState) { self.state = state }

  func readSelection(context: FinderSelectionContext) async -> FinderSelectionState {
    lock.withLock { count += 1 }
    return state
  }

  var callCount: Int { lock.withLock { count } }
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

  @Test func searchFieldDelegateRoutesEditingCommandsAndFallsBackForOrdinaryEditing() {
    var commands: [QuickSendCommand] = []
    var modifiers: NSEvent.ModifierFlags = []
    let coordinator = QuickSendSearchFieldCoordinator(
      setText: { _ in },
      command: { commands.append($0) },
      modifierFlags: { modifiers }
    )
    let field = NSSearchField()
    let editor = NSTextView()

    #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
    #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
    #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    modifiers = .command
    #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(!coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
    #expect(commands == [.up, .down, .primary, .secondary, .escape])
  }

  @Test func showReusesPanelActivatesEveryTimeCentersInitialFrameAndSchedulesFocus() {
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
    let firstFrame = panel.frame
    controller.show()

    #expect(controller.panelForTesting === firstPanel)
    #expect(activation.activationCount == 2)
    #expect(focus.lastResponder === searchField)
    #expect(panel.frame.midX == 900)
    #expect(panel.frame == firstFrame)
    panel.orderOut(nil)
  }

  @Test func repeatedShowWhileVisiblePreservesSessionAndHiddenShowRefreshesContext() async {
    let selectedURLs = [
      URL(fileURLWithPath: "/tmp/Selected.txt"),
      URL(fileURLWithPath: "/tmp/Also Selected.txt")
    ]
    let reader = CountingFinderReader(state: .selection(selectedURLs))
    let item = ShelfItem(title: "Source", kind: .file)
    let activation = ActivationSpy()
    let focus = FocusSchedulerSpy()
    let panel = QuickSendPanelController.makePanel(contentView: NSView())
    let searchField = NSSearchField()
    var contextCount = 0
    var mouseLocation = NSPoint(x: 250, y: 250)
    let model = QuickSendModel(
      finderReader: reader, items: { [item] }, history: { [] }, destinations: { [] },
      isUndoEligible: { _ in false }, performPrimary: { _ in }, dismiss: {}
    )
    let controller = QuickSendPanelController(
      model: model, panel: panel, activator: activation, focusScheduler: focus,
      finderContextProvider: {
        contextCount += 1
        return .finderWasFrontmost
      },
      mouseLocation: { mouseLocation },
      screenFrames: { [NSRect(x: 0, y: 0, width: 500, height: 500)] }
    )
    controller.registerSearchField(searchField)

    controller.show()
    while reader.callCount < 1 || model.results.isEmpty { await Task.yield() }
    model.setQuery("Source")
    model.selectResult("item:\(item.id)")
    model.performSecondary()
    model.setQuery("Selected")
    model.isOperationRunning = true
    let firstPanel = controller.panelForTesting
    let firstFrame = panel.frame
    let firstQuery = model.query
    let firstResults = model.results
    let firstFinderState = model.finderState
    let firstSelection = model.selectedResultID
    let firstSecondaryMode = model.secondaryMode
    mouseLocation = NSPoint(x: 450, y: 450)

    controller.show()
    await Task.yield()

    #expect(controller.panelForTesting === firstPanel)
    #expect(panel.frame == firstFrame)
    #expect(model.query == firstQuery)
    #expect(model.results == firstResults)
    #expect(model.finderState == firstFinderState)
    #expect(model.finderState == .selection(selectedURLs))
    #expect(model.query == "Selected")
    #expect(model.results.first?.semanticID.hasPrefix("finder:") == true)
    #expect(model.results.first?.finderURLs == selectedURLs)
    #expect(model.selectedResultID == firstSelection)
    #expect(model.secondaryMode == firstSecondaryMode)
    #expect(reader.callCount == 1)
    #expect(contextCount == 1)
    #expect(activation.activationCount == 2)
    #expect(focus.focusCount == 2)

    model.isOperationRunning = false
    panel.orderOut(nil)
    controller.show()
    while reader.callCount < 2 { await Task.yield() }

    #expect(contextCount == 2)
    #expect(activation.activationCount == 3)
    #expect(focus.focusCount == 3)
    panel.orderOut(nil)
  }

  @Test func showCapturesFinderEligibilityBeforeActivationAndRefreshUsesCapturedContext() async {
    var frontmostBundleID = "com.apple.finder"
    let activation = ActivationSpy()
    activation.onActivate = { frontmostBundleID = "dev.bruno.Barrel" }
    let execution = FinderExecutionSpy()
    let reader = FinderSelectionReader(execute: { execution.execute() })
    let model = QuickSendModel(
      finderReader: reader, items: { [] }, history: { [] }, destinations: { [] },
      isUndoEligible: { _ in false }, performPrimary: { _ in }, dismiss: {}
    )
    let panel = QuickSendPanelController.makePanel(contentView: NSView())
    let controller = QuickSendPanelController(
      model: model, panel: panel, activator: activation,
      finderContextProvider: { FinderSelectionContext(frontmostBundleID: frontmostBundleID) }
    )

    controller.show()
    while model.finderState == .unavailable { await Task.yield() }

    #expect(execution.callCount == 1)
    #expect(model.finderState == .selection([URL(fileURLWithPath: "/tmp/Selected.txt")]))
    #expect(frontmostBundleID == "dev.bruno.Barrel")
    panel.orderOut(nil)
  }

  @Test func showDoesNotReadFinderWhenAnotherAppWasFrontmostBeforeActivation() async {
    let execution = FinderExecutionSpy()
    let item = ShelfItem(title: "Existing", kind: .file)
    let model = QuickSendModel(
      finderReader: FinderSelectionReader(execute: { execution.execute() }),
      items: { [item] }, history: { [] }, destinations: { [] }, isUndoEligible: { _ in false },
      performPrimary: { _ in }, dismiss: {}
    )
    let panel = QuickSendPanelController.makePanel(contentView: NSView())
    let controller = QuickSendPanelController(
      model: model, panel: panel, activator: ActivationSpy(),
      finderContextProvider: { .otherAppWasFrontmost }
    )

    controller.show()
    while model.results.isEmpty { await Task.yield() }

    #expect(execution.callCount == 0)
    #expect(model.finderState == .unavailable)
    panel.orderOut(nil)
  }

  @Test func escapeClosesSecondaryLayerBeforeOrderingOutPanel() async {
    let panel = QuickSendPanelController.makePanel(contentView: NSView())
    let model = makeModel()
    let controller = QuickSendPanelController(model: model, panel: panel)
    panel.orderFront(nil)

    #expect(controller.handleEscape() == .dismissPanel)
    #expect(!panel.isVisible)
  }

  @Test func escapeCommandClosesLayerThenOrdersOutPanelThroughControllerPath() async {
    let item = ShelfItem(title: "Source", kind: .file)
    let destination = RecentDestination(
      id: "/Destination", name: "Destination", url: URL(fileURLWithPath: "/Destination"),
      bookmark: nil, lastUsedAt: .now
    )
    let model = QuickSendModel(
      finderReader: EmptyFinderReader(), items: { [item] }, history: { [] },
      destinations: { [destination] }, isUndoEligible: { _ in false },
      performPrimary: { _ in }, exportItem: { _, _ in .dismiss }, dismiss: {}
    )
    let panel = QuickSendPanelController.makePanel(contentView: NSView())
    let controller = QuickSendPanelController(model: model, panel: panel)
    await model.refresh()
    panel.orderFront(nil)
    model.performPrimary()

    #expect(controller.handleEscape() == .closedLayer)
    #expect(panel.isVisible)
    #expect(controller.handleEscape() == .dismissPanel)
    #expect(!panel.isVisible)
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
