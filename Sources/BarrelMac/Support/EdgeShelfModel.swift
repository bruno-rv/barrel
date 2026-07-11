import AppKit

enum ShelfEdge: String, Equatable {
  case left
  case right
}

enum EdgeShelfPhase: Equatable {
  case hidden
  case revealPending
  case shown
  case hidePending
  case dragLocked
}

enum EdgeShelfEvent: Equatable {
  case edgeEntered
  case edgeExited
  case revealDelayElapsed
  case pointerEnteredPanel
  case pointerExitedPanel
  case hideDelayElapsed
  case dragBegan
  case dragEnded(pointerInside: Bool)
  case explicitShow
  case autoHideChanged(isEnabled: Bool, pointerInside: Bool)
}

enum EdgeShelfEffect: Equatable {
  case scheduleReveal
  case cancelReveal
  case show
  case scheduleHide
  case cancelHide
  case hide
}

struct EdgeShelfStateMachine {
  private(set) var phase: EdgeShelfPhase

  init(phase: EdgeShelfPhase = .hidden) {
    self.phase = phase
  }

  mutating func handle(_ event: EdgeShelfEvent) -> [EdgeShelfEffect] {
    switch (phase, event) {
    case (.hidden, .edgeEntered):
      phase = .revealPending
      return [.scheduleReveal]
    case (.revealPending, .edgeExited):
      phase = .hidden
      return [.cancelReveal]
    case (.revealPending, .revealDelayElapsed):
      phase = .shown
      return [.show]
    case (.shown, .pointerExitedPanel):
      phase = .hidePending
      return [.scheduleHide]
    case (.hidePending, .pointerEnteredPanel):
      phase = .shown
      return [.cancelHide]
    case (.hidePending, .hideDelayElapsed):
      phase = .hidden
      return [.hide]
    case (.shown, .dragBegan), (.hidePending, .dragBegan):
      phase = .dragLocked
      return [.cancelHide]
    case (.revealPending, .dragBegan):
      phase = .dragLocked
      return [.cancelReveal, .show]
    case (.dragLocked, .dragEnded(pointerInside: true)):
      phase = .shown
      return []
    case (.dragLocked, .dragEnded(pointerInside: false)):
      phase = .hidePending
      return [.scheduleHide]
    case (.revealPending, .explicitShow):
      phase = .shown
      return [.cancelReveal, .show]
    case (.hidePending, .explicitShow):
      phase = .shown
      return [.cancelHide, .show]
    case (.hidden, .explicitShow), (.shown, .explicitShow):
      phase = .shown
      return [.show]
    case (.dragLocked, .explicitShow):
      return [.show]
    case (.revealPending, .autoHideChanged(isEnabled: false, pointerInside: _)):
      phase = .shown
      return [.cancelReveal, .show]
    case (.hidePending, .autoHideChanged(isEnabled: false, pointerInside: _)):
      phase = .shown
      return [.cancelHide, .show]
    case (.hidden, .autoHideChanged(isEnabled: false, pointerInside: _)):
      phase = .shown
      return [.show]
    case (.shown, .autoHideChanged(isEnabled: true, pointerInside: false)):
      phase = .hidePending
      return [.scheduleHide]
    default:
      return []
    }
  }
}

struct ShelfDisplayGeometry: Equatable {
  let frame: NSRect
  let visibleFrame: NSRect
}

struct ShelfPanelLayout {
  let panelSize = NSSize(width: 280, height: 480)
  let shownInset: CGFloat = 8
  let activationWidth: CGFloat = 3

  func targetFrame(
    shown: Bool,
    edge: ShelfEdge,
    display: ShelfDisplayGeometry
  ) -> NSRect {
    let centeredY = display.visibleFrame.midY - panelSize.height / 2
    let minimumY = display.visibleFrame.minY + 12
    let maximumY = display.visibleFrame.maxY - panelSize.height - 12
    let y = max(min(centeredY, maximumY), minimumY)
    let x: CGFloat

    switch (edge, shown) {
    case (.left, true):
      x = display.frame.minX + shownInset
    case (.left, false):
      x = display.frame.minX - panelSize.width
    case (.right, true):
      x = display.frame.maxX - panelSize.width - shownInset
    case (.right, false):
      x = display.frame.maxX
    }

    return NSRect(origin: NSPoint(x: x, y: y), size: panelSize)
  }

  func isActivationPoint(
    _ point: NSPoint,
    edge: ShelfEdge,
    display: ShelfDisplayGeometry
  ) -> Bool {
    let x: CGFloat
    switch edge {
    case .left:
      x = display.frame.minX
    case .right:
      x = display.frame.maxX - activationWidth
    }

    return NSRect(
      x: x,
      y: display.frame.minY,
      width: activationWidth,
      height: display.frame.height
    ).contains(point)
  }
}
