import AppKit
import SwiftUI

@MainActor
protocol QuickSendActivating {
  func activate()
}

@MainActor
protocol QuickSendFocusScheduling {
  func scheduleFocus(_ responder: NSResponder, in window: NSWindow)
}

@MainActor
private struct ApplicationQuickSendActivator: QuickSendActivating {
  func activate() {
    NSApp.activate(ignoringOtherApps: true)
  }
}

@MainActor
private struct MainQueueQuickSendFocusScheduler: QuickSendFocusScheduling {
  func scheduleFocus(_ responder: NSResponder, in window: NSWindow) {
    DispatchQueue.main.async { window.makeFirstResponder(responder) }
  }
}

final class QuickSendPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickSendPanelController: NSObject, NSWindowDelegate {
  private let model: QuickSendModel
  private let panel: QuickSendPanel
  private let activator: any QuickSendActivating
  private let focusScheduler: any QuickSendFocusScheduling
  private let mouseLocation: () -> NSPoint
  private let screenFrames: () -> [NSRect]
  private weak var searchField: NSSearchField?

  var panelForTesting: NSPanel { panel }

  init(
    model: QuickSendModel,
    panel: QuickSendPanel? = nil,
    activator: (any QuickSendActivating)? = nil,
    focusScheduler: (any QuickSendFocusScheduling)? = nil,
    mouseLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
    screenFrames: @escaping () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) }
  ) {
    self.model = model
    self.panel = panel ?? Self.makePanel(contentView: NSView())
    self.activator = activator ?? ApplicationQuickSendActivator()
    self.focusScheduler = focusScheduler ?? MainQueueQuickSendFocusScheduler()
    self.mouseLocation = mouseLocation
    self.screenFrames = screenFrames
    super.init()
    self.panel.delegate = self
    self.panel.contentView = NSHostingView(rootView: QuickSendView(
      model: model,
      registerSearchField: { [weak self] in self?.registerSearchField($0) },
      dismiss: { [weak self] in self?.orderOut() }
    ))
  }

  convenience init(store: ShelfStore) {
    final class PanelReference { weak var panel: NSPanel? }
    let reference = PanelReference()
    let model = QuickSendModel(
      store: store,
      finderReader: FinderSelectionReader(),
      destinationResolver: RecentDestinationResolver(),
      dismiss: { reference.panel?.orderOut(nil) }
    )
    self.init(model: model)
    reference.panel = panelForTesting
  }

  static func makePanel(contentView: NSView) -> QuickSendPanel {
    let size = NSSize(width: 520, height: 460)
    let panel = QuickSendPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
    )
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.contentView = contentView
    return panel
  }

  func show() {
    activator.activate()
    centerOnActiveScreen()
    panel.makeKeyAndOrderFront(nil)
    Task { await model.refresh() }
    if let searchField { focusScheduler.scheduleFocus(searchField, in: panel) }
  }

  func orderOut() { panel.orderOut(nil) }

  func registerSearchField(_ searchField: NSSearchField) {
    self.searchField = searchField
    if panel.isVisible { focusScheduler.scheduleFocus(searchField, in: panel) }
  }

  @discardableResult
  func handleEscape() -> Bool { model.handleEscape() }

  func windowDidResignKey(_ notification: Notification) {
    if !model.isOperationRunning { orderOut() }
  }

  private func centerOnActiveScreen() {
    let point = mouseLocation()
    guard let screen = screenFrames().first(where: { $0.contains(point) }) ?? screenFrames().first else {
      panel.center()
      return
    }
    panel.setFrameOrigin(NSPoint(
      x: screen.midX - panel.frame.width / 2,
      y: screen.midY - panel.frame.height / 2
    ))
  }
}
