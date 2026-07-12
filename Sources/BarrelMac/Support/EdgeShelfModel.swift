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
  case minimumVisibilityElapsed
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
  case scheduleMinimumVisibility
  case rememberPendingHide
  case forgetPendingHide
  case scheduleHide
  case cancelHide
  case hide
}

struct EdgeShelfStateMachine {
  private(set) var phase: EdgeShelfPhase
  private var isMinimumVisibilityElapsed: Bool
  private var isPointerInsidePanel: Bool
  private var isDragActive: Bool
  private var hasPendingHide = false

  init(phase: EdgeShelfPhase = .hidden) {
    self.phase = phase
    self.isMinimumVisibilityElapsed = phase == .hidePending
    self.isPointerInsidePanel = phase == .shown
    self.isDragActive = phase == .dragLocked
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
      isMinimumVisibilityElapsed = false
      return [.show, .scheduleMinimumVisibility]
    case (.shown, .pointerExitedPanel):
      isPointerInsidePanel = false
      if isMinimumVisibilityElapsed {
        phase = .hidden
        return [.hide]
      }
      hasPendingHide = true
      return [.rememberPendingHide]
    case (.shown, .pointerEnteredPanel), (.hidePending, .pointerEnteredPanel):
      isPointerInsidePanel = true
      hasPendingHide = false
      phase = .shown
      return [.forgetPendingHide]
    case (.shown, .minimumVisibilityElapsed), (.dragLocked, .minimumVisibilityElapsed):
      isMinimumVisibilityElapsed = true
      if hasPendingHide && !isPointerInsidePanel && !isDragActive {
        hasPendingHide = false
        phase = .hidden
        return [.hide]
      }
      return []
    case (.hidePending, .hideDelayElapsed):
      phase = .hidden
      return [.hide]
    case (.shown, .dragBegan), (.hidePending, .dragBegan):
      isDragActive = true
      hasPendingHide = false
      phase = .dragLocked
      return [.forgetPendingHide]
    case (.hidden, .dragBegan):
      isDragActive = true
      isMinimumVisibilityElapsed = false
      phase = .dragLocked
      return [.show, .scheduleMinimumVisibility]
    case (.revealPending, .dragBegan):
      isDragActive = true
      isMinimumVisibilityElapsed = false
      phase = .dragLocked
      return [.cancelReveal, .show, .scheduleMinimumVisibility]
    case (.dragLocked, .dragEnded(pointerInside: true)):
      isDragActive = false
      isPointerInsidePanel = true
      phase = .shown
      return []
    case (.dragLocked, .dragEnded(pointerInside: false)):
      isDragActive = false
      isPointerInsidePanel = false
      if isMinimumVisibilityElapsed {
        phase = .hidden
        return [.hide]
      }
      hasPendingHide = true
      phase = .shown
      return [.rememberPendingHide]
    case (.revealPending, .explicitShow):
      phase = .shown
      isMinimumVisibilityElapsed = false
      return [.cancelReveal, .show, .scheduleMinimumVisibility]
    case (.hidePending, .explicitShow):
      phase = .shown
      isMinimumVisibilityElapsed = false
      return [.cancelHide, .show, .scheduleMinimumVisibility]
    case (.hidden, .explicitShow), (.shown, .explicitShow):
      phase = .shown
      isMinimumVisibilityElapsed = false
      return [.show, .scheduleMinimumVisibility]
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
