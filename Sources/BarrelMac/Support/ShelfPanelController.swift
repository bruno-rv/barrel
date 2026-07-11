import AppKit
import SwiftUI

final class ShelfPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class ShelfPanelController {
  private let panel: ShelfPanel
  private let edgeController: EdgeShelfController

  init(store: ShelfStore, defaults: UserDefaults = .standard) {
    let panel = Self.makePanel(contentView: NSView())
    let edgeController = EdgeShelfController(panel: panel, defaults: defaults)
    panel.contentView = NSHostingView(rootView: ContentView(store: store))
    self.panel = panel
    self.edgeController = edgeController
  }

  static func makePanel(contentView: NSView) -> ShelfPanel {
    let size = ShelfPanelLayout().panelSize
    let panel = ShelfPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .stationary,
      .ignoresCycle
    ]
    contentView.frame = NSRect(origin: .zero, size: size)
    panel.contentView = contentView
    return panel
  }

  func start() { edgeController.start() }
  func stop() { edgeController.stop() }
  func showShelf() { edgeController.showExplicitly() }

  func setDropTargeted(_ targeted: Bool) {
    edgeController.setDropTargeted(targeted)
  }
}
