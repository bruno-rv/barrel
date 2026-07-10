import AppKit
import SwiftUI

struct WindowConfigurator: NSViewRepresentable {
  let edge: String
  let autoHide: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(edge: edge, autoHide: autoHide)
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      if let window = view.window {
        context.coordinator.attach(window: window)
      }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.configure(edge: edge, autoHide: autoHide)
    if let window = nsView.window {
      context.coordinator.attach(window: window)
    }
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.stop()
  }

  final class Coordinator {
    private weak var window: NSWindow?
    private var timer: Timer?
    private var edge: String
    private var autoHide: Bool
    private var isShown = true
    private var didPlaceInitialWindow = false

    private let shelfSize = NSSize(width: 310, height: 560)
    private let visibleInset: CGFloat = 18
    private let hiddenSliverWidth: CGFloat = 7
    private let edgeHotZoneWidth: CGFloat = 3
    private let hideMargin: CGFloat = 20

    init(edge: String, autoHide: Bool) {
      self.edge = edge
      self.autoHide = autoHide
    }

    func attach(window: NSWindow) {
      self.window = window
      configureWindow(window)
      start()

      if !didPlaceInitialWindow {
        didPlaceInitialWindow = true
        isShown = !autoHide
        position(window: window, shown: isShown, animated: false, screen: window.screen ?? NSScreen.main)
      }
    }

    func configure(edge: String, autoHide: Bool) {
      let edgeChanged = self.edge != edge
      let autoHideChanged = self.autoHide != autoHide
      self.edge = edge
      self.autoHide = autoHide

      guard let window else {
        return
      }

      if edgeChanged || autoHideChanged {
        isShown = !autoHide
        position(window: window, shown: isShown, animated: true, screen: screenForCurrentMouse() ?? window.screen ?? NSScreen.main)
      }
    }

    func stop() {
      timer?.invalidate()
      timer = nil
    }

    private func configureWindow(_ window: NSWindow) {
      window.level = .floating
      window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary, .stationary])
      window.isMovableByWindowBackground = true
      window.isOpaque = false
      window.backgroundColor = .clear
      window.hasShadow = true
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.standardWindowButton(.zoomButton)?.isHidden = true
      window.standardWindowButton(.miniaturizeButton)?.isHidden = true
      window.setContentSize(shelfSize)
    }

    private func start() {
      guard timer == nil else {
        return
      }
      timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
        self?.tick()
      }
      RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
      guard autoHide, let window else {
        return
      }

      let mouse = NSEvent.mouseLocation
      guard let screen = screen(containing: mouse) ?? window.screen ?? NSScreen.main else {
        return
      }
      let frame = window.frame

      if isShown {
        let generousFrame = frame.insetBy(dx: -hideMargin, dy: -hideMargin)
        if !generousFrame.contains(mouse) {
          isShown = false
          position(window: window, shown: false, animated: true, screen: screen)
        }
      } else if isMouseAtActivationEdge(mouse, screen: screen) {
        isShown = true
        position(window: window, shown: true, animated: true, screen: screen)
        window.orderFrontRegardless()
      }
    }

    private func position(window: NSWindow, shown: Bool, animated: Bool, screen: NSScreen?) {
      guard let screen else {
        return
      }

      let frame = targetFrame(shown: shown, screen: screen)
      if animated {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.16
          context.timingFunction = CAMediaTimingFunction(name: .easeOut)
          window.animator().setFrame(frame, display: true)
        }
      } else {
        window.setFrame(frame, display: true)
      }
    }

    private func targetFrame(shown: Bool, screen: NSScreen) -> NSRect {
      let visible = screen.visibleFrame
      let y = min(max(visible.midY - shelfSize.height / 2, visible.minY + 12), visible.maxY - shelfSize.height - 12)
      let isRight = edge == "right"
      let x: CGFloat

      if shown {
        x = isRight ? visible.maxX - shelfSize.width - visibleInset : visible.minX + visibleInset
      } else {
        x = isRight ? visible.maxX - hiddenSliverWidth : visible.minX - shelfSize.width + hiddenSliverWidth
      }

      return NSRect(origin: NSPoint(x: x, y: y), size: shelfSize)
    }

    private func isMouseAtActivationEdge(_ mouse: NSPoint, screen: NSScreen) -> Bool {
      let visible = screen.visibleFrame
      if edge == "right" {
        return mouse.x >= visible.maxX - edgeHotZoneWidth
      }
      return mouse.x <= visible.minX + edgeHotZoneWidth
    }

    private func screenForCurrentMouse() -> NSScreen? {
      screen(containing: NSEvent.mouseLocation)
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
      NSScreen.screens.first { $0.frame.contains(point) }
    }
  }
}
