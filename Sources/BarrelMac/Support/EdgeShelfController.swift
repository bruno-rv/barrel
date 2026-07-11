import AppKit

struct ShelfScreen: Equatable {
  let displayID: CGDirectDisplayID
  let frame: NSRect
  let visibleFrame: NSRect
  let isMain: Bool
}

enum ShelfScreenResolver {
  static func resolve(
    point: NSPoint,
    trackedDisplayID: CGDirectDisplayID?,
    screens: [ShelfScreen]
  ) -> ShelfScreen? {
    screens.first(where: { $0.frame.contains(point) })
      ?? screens.first(where: { $0.displayID == trackedDisplayID })
      ?? screens.first(where: \.isMain)
      ?? screens.first
  }
}

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
  private var lifecycleGeneration = 0
  private var isRunning = false
  private var isDropTargeted = false
  private var currentEdge: ShelfEdge
  private var currentAutoHide: Bool
  private let mouseLocation: @MainActor () -> NSPoint
  private let screens: @MainActor () -> [ShelfScreen]
  private let resolveScreen: (NSPoint, CGDirectDisplayID?, [ShelfScreen]) -> ShelfScreen?
  private(set) var trackedDisplayID: CGDirectDisplayID?

  init(
    panel: NSPanel,
    defaults: UserDefaults,
    mouseLocation: @escaping @MainActor () -> NSPoint = { NSEvent.mouseLocation },
    screens: @escaping @MainActor () -> [ShelfScreen] = EdgeShelfController.availableScreens,
    resolveScreen: @escaping (NSPoint, CGDirectDisplayID?, [ShelfScreen]) -> ShelfScreen? =
      ShelfScreenResolver.resolve
  ) {
    self.panel = panel
    self.defaults = defaults
    self.mouseLocation = mouseLocation
    self.screens = screens
    self.resolveScreen = resolveScreen
    ShelfWindowPreferences.migrate(defaults)
    self.currentEdge = Self.edge(in: defaults)
    self.currentAutoHide = defaults.bool(forKey: ShelfWindowPreferences.autoHideKey)
  }

  func start() {
    guard localMonitor == nil, globalMonitor == nil else { return }
    lifecycleGeneration &+= 1
    let generation = lifecycleGeneration
    isRunning = true

    let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      MainActor.assumeIsolated {
        guard self?.isCurrent(generation) == true else { return }
        self?.handle(event)
      }
      return event
    }
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
      Task { @MainActor in
        guard self?.isCurrent(generation) == true else { return }
        self?.handle(event)
      }
    }

    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard self?.isCurrent(generation) == true else { return }
        self?.refreshPanelFrame()
      }
    })
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard self?.isCurrent(generation) == true else { return }
        self?.refreshPanelFrame()
      }
    })
    observers.append(center.addObserver(
      forName: UserDefaults.didChangeNotification,
      object: defaults,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard self?.isCurrent(generation) == true else { return }
        self?.settingsDidChange()
      }
    })

    refreshPanelFrame()
    let point = mouseLocation()
    apply(machine.handle(.autoHideChanged(
      isEnabled: autoHideEnabled,
      pointerInside: panel?.frame.contains(point) == true
    )), point: point)
  }

  func stop() {
    isRunning = false
    lifecycleGeneration &+= 1
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
    isDropTargeted = false
    machine = EdgeShelfStateMachine()
  }

  func showExplicitly() {
    apply(machine.handle(.explicitShow), point: mouseLocation())
  }

  func setDropTargeted(_ targeted: Bool) {
    guard targeted != isDropTargeted else { return }
    isDropTargeted = targeted
    guard targeted else { return }
    let point = mouseLocation()
    apply(machine.handle(.dragBegan), point: point)
  }

  func settingsDidChange() {
    let newEdge = Self.edge(in: defaults)
    let newAutoHide = defaults.bool(forKey: ShelfWindowPreferences.autoHideKey)
    let edgeChanged = newEdge != currentEdge
    let autoHideChanged = newAutoHide != currentAutoHide
    guard edgeChanged || autoHideChanged else { return }
    currentEdge = newEdge
    currentAutoHide = newAutoHide

    if autoHideChanged {
      cancelReveal()
      cancelHide()
      let point = mouseLocation()
      apply(machine.handle(.autoHideChanged(
        isEnabled: newAutoHide,
        pointerInside: panel?.frame.contains(point) == true
      )), point: point)
    }
    if edgeChanged { refreshPanelFrame() }
  }

  private var edge: ShelfEdge {
    currentEdge
  }

  private var autoHideEnabled: Bool {
    currentAutoHide
  }

  private func handle(_ event: NSEvent) {
    let point = mouseLocation()
    guard let screen = resolvedScreen(containing: point) else { return }
    let display = geometry(for: screen)
    let insidePanel = panel?.frame.contains(point) == true
    let atEdge = layout.isActivationPoint(point, edge: edge, display: display)
    let isActive = [.shown, .hidePending, .dragLocked].contains(machine.phase)

    if isActive, screen.displayID != trackedDisplayID {
      if machine.phase == .hidePending, atEdge {
        apply(machine.handle(.explicitShow), point: point)
        return
      }
      placePanel(shown: true, on: screen)
      panel?.orderFrontRegardless()
    }

    switch event.type {
    case .leftMouseDragged:
      let alreadyShown = [.shown, .hidePending, .dragLocked].contains(machine.phase)
      if alreadyShown || insidePanel || atEdge {
        if machine.phase == .hidden && atEdge {
          apply(machine.handle(.edgeEntered), point: point)
        }
        apply(machine.handle(.dragBegan), point: point)
      }
    case .leftMouseUp:
      isDropTargeted = false
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
        let generation = lifecycleGeneration
        let item = DispatchWorkItem { [weak self] in
          MainActor.assumeIsolated {
            guard let self, self.isCurrent(generation) else { return }
            self.revealWorkItem = nil
            self.apply(self.machine.handle(.revealDelayElapsed), point: self.mouseLocation())
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
        let generation = lifecycleGeneration
        let item = DispatchWorkItem { [weak self] in
          MainActor.assumeIsolated {
            guard let self, self.isCurrent(generation) else { return }
            self.hideWorkItem = nil
            self.apply(self.machine.handle(.hideDelayElapsed), point: self.mouseLocation())
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
    setPanelFrame(shown: shown, point: mouseLocation())
    if shown { panel?.orderFrontRegardless() }
  }

  private func setPanelFrame(shown: Bool, point: NSPoint) {
    guard let screen = resolvedScreen(containing: point) else {
      trackedDisplayID = nil
      return
    }
    placePanel(shown: shown, on: screen)
  }

  private func placePanel(shown: Bool, on screen: ShelfScreen) {
    trackedDisplayID = screen.displayID
    let frame = layout.targetFrame(shown: shown, edge: edge, display: geometry(for: screen))
    panel?.setFrame(frame, display: true, animate: false)
  }

  private func resolvedScreen(containing point: NSPoint) -> ShelfScreen? {
    resolveScreen(point, trackedDisplayID, screens())
  }

  private func geometry(for screen: ShelfScreen) -> ShelfDisplayGeometry {
    ShelfDisplayGeometry(frame: screen.frame, visibleFrame: screen.visibleFrame)
  }

  private static func availableScreens() -> [ShelfScreen] {
    NSScreen.screens.compactMap { screen in
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
        return nil
      }
      return ShelfScreen(
        displayID: number.uint32Value,
        frame: screen.frame,
        visibleFrame: screen.visibleFrame,
        isMain: screen == NSScreen.main
      )
    }
  }

  private func isCurrent(_ generation: Int) -> Bool {
    isRunning && lifecycleGeneration == generation
  }

  private static func edge(in defaults: UserDefaults) -> ShelfEdge {
    ShelfEdge(rawValue: defaults.string(forKey: ShelfWindowPreferences.edgeKey) ?? "") ?? .left
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
