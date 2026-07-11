import AppKit

@MainActor
final class EdgeShelfController {
  private weak var panel: NSPanel?
  private var machine = EdgeShelfStateMachine()
  private let layout = ShelfPanelLayout()
  private let defaults: UserDefaults
  private var localMonitor: Any?
  private var globalMonitor: Any?
  private var observers: [NSObjectProtocol] = []
  private var revealWorkItem: DispatchWorkItem?
  private var hideWorkItem: DispatchWorkItem?

  init(panel: NSPanel, defaults: UserDefaults) {
    self.panel = panel
    self.defaults = defaults
    ShelfWindowPreferences.migrate(defaults)
  }

  func start() {
    guard localMonitor == nil, globalMonitor == nil else { return }

    let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      MainActor.assumeIsolated {
        self?.handle(event)
      }
      return event
    }
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
      Task { @MainActor in
        self?.handle(event)
      }
    }

    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refreshPanelFrame() }
    })
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refreshPanelFrame() }
    })

    refreshPanelFrame()
    let point = NSEvent.mouseLocation
    apply(machine.handle(.autoHideChanged(
      isEnabled: autoHideEnabled,
      pointerInside: panel?.frame.contains(point) == true
    )), point: point)
  }

  func stop() {
    if let localMonitor {
      NSEvent.removeMonitor(localMonitor)
      self.localMonitor = nil
    }
    if let globalMonitor {
      NSEvent.removeMonitor(globalMonitor)
      self.globalMonitor = nil
    }
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    observers.removeAll()
    cancelReveal()
    cancelHide()
  }

  func showExplicitly() {
    apply(machine.handle(.explicitShow), point: NSEvent.mouseLocation)
  }

  func setDropTargeted(_ targeted: Bool) {
    let point = NSEvent.mouseLocation
    let event: EdgeShelfEvent = targeted
      ? .dragBegan
      : .dragEnded(pointerInside: panel?.frame.contains(point) == true)
    apply(machine.handle(event), point: point)
  }

  private var edge: ShelfEdge {
    ShelfEdge(rawValue: defaults.string(forKey: ShelfWindowPreferences.edgeKey) ?? "") ?? .left
  }

  private var autoHideEnabled: Bool {
    defaults.bool(forKey: ShelfWindowPreferences.autoHideKey)
  }

  private func handle(_ event: NSEvent) {
    let point = NSEvent.mouseLocation
    guard let screen = screen(containing: point) else { return }
    let display = geometry(for: screen)
    let insidePanel = panel?.frame.contains(point) == true
    let atEdge = layout.isActivationPoint(point, edge: edge, display: display)

    switch event.type {
    case .leftMouseDragged:
      let alreadyShown = [.shown, .hidePending, .dragLocked].contains(machine.phase)
      if alreadyShown || insidePanel || atEdge {
        apply(machine.handle(.dragBegan), point: point)
      }
    case .leftMouseUp:
      apply(machine.handle(.dragEnded(pointerInside: insidePanel)), point: point)
    default:
      apply(machine.handle(atEdge ? .edgeEntered : .edgeExited), point: point)
      if autoHideEnabled {
        apply(machine.handle(insidePanel ? .pointerEnteredPanel : .pointerExitedPanel), point: point)
      }
    }
  }

  private func apply(_ effects: [EdgeShelfEffect], point: NSPoint) {
    for effect in effects {
      switch effect {
      case .scheduleReveal:
        cancelHide()
        cancelReveal()
        let item = DispatchWorkItem { [weak self] in
          MainActor.assumeIsolated {
            guard let self else { return }
            self.revealWorkItem = nil
            self.apply(self.machine.handle(.revealDelayElapsed), point: NSEvent.mouseLocation)
          }
        }
        revealWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: item)
      case .cancelReveal:
        cancelReveal()
      case .show:
        cancelReveal()
        cancelHide()
        setPanelFrame(shown: true, point: point)
        panel?.orderFrontRegardless()
      case .scheduleHide:
        cancelReveal()
        cancelHide()
        let item = DispatchWorkItem { [weak self] in
          MainActor.assumeIsolated {
            guard let self else { return }
            self.hideWorkItem = nil
            self.apply(self.machine.handle(.hideDelayElapsed), point: NSEvent.mouseLocation)
          }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
      case .cancelHide:
        cancelHide()
      case .hide:
        cancelReveal()
        cancelHide()
        setPanelFrame(shown: false, point: point)
      }
    }
  }

  private func refreshPanelFrame() {
    let shown = [.shown, .hidePending, .dragLocked].contains(machine.phase)
    setPanelFrame(shown: shown, point: NSEvent.mouseLocation)
    if shown { panel?.orderFrontRegardless() }
  }

  private func setPanelFrame(shown: Bool, point: NSPoint) {
    guard let screen = screen(containing: point) else { return }
    let frame = layout.targetFrame(shown: shown, edge: edge, display: geometry(for: screen))
    panel?.setFrame(frame, display: true, animate: false)
  }

  private func screen(containing point: NSPoint) -> NSScreen? {
    NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main ?? NSScreen.screens.first
  }

  private func geometry(for screen: NSScreen) -> ShelfDisplayGeometry {
    ShelfDisplayGeometry(frame: screen.frame, visibleFrame: screen.visibleFrame)
  }

  private func cancelReveal() {
    revealWorkItem?.cancel()
    revealWorkItem = nil
  }

  private func cancelHide() {
    hideWorkItem?.cancel()
    hideWorkItem = nil
  }

  deinit {
    revealWorkItem?.cancel()
    hideWorkItem?.cancel()
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
  }
}
