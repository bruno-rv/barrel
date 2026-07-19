import AppKit
import SwiftUI

final class ShelfPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class ShelfPanelController {
  /// Above ordinary and full-screen app windows; below the menu bar itself.
  static let shelfWindowLevel = NSWindow.Level(
    rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2
  )
  static let shelfCollectionBehavior: NSWindow.CollectionBehavior = [
    .canJoinAllSpaces,
    .fullScreenAuxiliary,
    .stationary,
    .ignoresCycle
  ]

  private let panel: ShelfPanel
  private let edgeController: EdgeShelfController

  init(store: ShelfStore, defaults: UserDefaults = .standard) {
    let panel = Self.makePanel(contentView: NSView())
    let edgeController = EdgeShelfController(panel: panel, defaults: defaults)
    self.panel = panel
    self.edgeController = edgeController
    panel.contentView = NSHostingView(
      rootView: ContentView(store: store) { [weak self] targeted in
        self?.setDropTargeted(targeted)
      }
    )
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
    panel.level = shelfWindowLevel
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = shelfCollectionBehavior
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
