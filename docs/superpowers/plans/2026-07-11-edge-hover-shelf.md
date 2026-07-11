# Edge-hover shelf implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Barrel's normal shelf window with a compact, non-activating
panel that follows the pointer across displays and remains available over
full-screen macOS applications.

**Architecture:** Keep shelf data and SwiftUI content unchanged, but move shelf
window ownership into `ShelfPanelController`. Drive visibility with a testable
edge state machine and an AppKit event controller; retain SwiftUI scenes only
for the menu-bar extra and Settings.

**Tech Stack:** Swift 6 package, SwiftUI, AppKit `NSPanel`, XCTest, macOS 14.

## Global constraints

- Support macOS 14 and later.
- Use one 280-by-480-point shelf panel, not one panel per display.
- Default to left-edge auto-hide while retaining right-edge and persistent
  options.
- Reveal at a two-to-three-point edge after about 100 milliseconds.
- Hide about 250 milliseconds after leaving.
- Do not activate Barrel during hover or drag reveal.
- Keep the panel open throughout inbound and outbound drag sessions.
- Use events and cancellable delayed work, not a repeating polling timer.
- Do not change repository, item, retention, Spotlight, or CloudKit formats.
- Add no third-party dependency.

---

### Task 1: Edge state and display geometry

**Files:**

- Create: `Sources/BarrelMac/Support/EdgeShelfModel.swift`
- Create: `Tests/BarrelMacTests/EdgeShelfModelTests.swift`

**Interfaces:**

- Produces: `ShelfEdge`, `EdgeShelfPhase`, `EdgeShelfEvent`,
  `EdgeShelfEffect`, `EdgeShelfStateMachine`, and `ShelfPanelLayout`.
- Consumes: AppKit `NSPoint`, `NSRect`, and `NSSize` value types only.

- [ ] **Step 1: Write failing state-transition tests**

Add tests covering delayed reveal, canceled reveal, delayed hide, canceled hide,
drag lock, mouse-up outside, explicit reveal, and disabling auto-hide:

```swift
import AppKit
import XCTest
@testable import BarrelMac

final class EdgeShelfModelTests: XCTestCase {
  func testEdgeEntrySchedulesRevealAndElapsedDelayShowsPanel() {
    var machine = EdgeShelfStateMachine()

    XCTAssertEqual(machine.handle(.edgeEntered), [.scheduleReveal])
    XCTAssertEqual(machine.phase, .revealPending)
    XCTAssertEqual(machine.handle(.revealDelayElapsed), [.show])
    XCTAssertEqual(machine.phase, .shown)
  }

  func testLeavingBeforeRevealCancelsPendingReveal() {
    var machine = EdgeShelfStateMachine()
    _ = machine.handle(.edgeEntered)

    XCTAssertEqual(machine.handle(.edgeExited), [.cancelReveal])
    XCTAssertEqual(machine.phase, .hidden)
  }

  func testDragKeepsShownShelfOpenUntilMouseUpOutside() {
    var machine = EdgeShelfStateMachine(phase: .shown)

    XCTAssertEqual(machine.handle(.dragBegan), [.cancelHide])
    XCTAssertEqual(machine.phase, .dragLocked)
    XCTAssertEqual(
      machine.handle(.dragEnded(pointerInside: false)),
      [.scheduleHide]
    )
    XCTAssertEqual(machine.phase, .hidePending)
    XCTAssertEqual(machine.handle(.hideDelayElapsed), [.hide])
  }
}
```

- [ ] **Step 2: Write failing geometry tests**

Use a display frame of `1920 × 1080` and visible frame of
`1920 × 1055`. Verify the shown left frame is inset, the hidden left frame ends
at `display.frame.minX`, right-edge frames mirror correctly, the panel size is
`280 × 480`, and the activation zone uses the full display frame rather than
the visible frame.

```swift
func testHiddenLeftFrameIsCompletelyOffscreen() {
  let layout = ShelfPanelLayout()
  let display = ShelfDisplayGeometry(
    frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
    visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1055)
  )

  let frame = layout.targetFrame(shown: false, edge: .left, display: display)

  XCTAssertEqual(frame.size, NSSize(width: 280, height: 480))
  XCTAssertEqual(frame.maxX, display.frame.minX)
}
```

- [ ] **Step 3: Run the tests to verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter EdgeShelfModelTests
```

Expected: compilation fails because the edge model types do not exist.

- [ ] **Step 4: Implement the pure state machine**

Define these exact cases and make every event idempotent when it does not apply
to the current phase:

```swift
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
    case (.shown, .dragBegan):
      phase = .dragLocked
      return [.cancelHide]
    case (.hidePending, .dragBegan):
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
```

The exhaustive switch must implement the effects asserted by the tests. An
explicit show cancels pending delayed work and returns `.show`. Disabling
auto-hide shows the panel. Re-enabling auto-hide schedules a hide only when the
pointer is outside.

- [ ] **Step 5: Implement display geometry**

Add value types with these defaults:

```swift
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
  ) -> NSRect

  func isActivationPoint(
    _ point: NSPoint,
    edge: ShelfEdge,
    display: ShelfDisplayGeometry
  ) -> Bool
}
```

Center vertically inside `visibleFrame`, clamp to a 12-point vertical margin,
and place the complete panel beyond `display.frame` when hidden.

- [ ] **Step 6: Run focused and full tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter EdgeShelfModelTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: all edge-model tests and the existing 53 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/BarrelMac/Support/EdgeShelfModel.swift \
  Tests/BarrelMacTests/EdgeShelfModelTests.swift
git commit -m "feat: model edge shelf visibility"
```

---

### Task 2: One-time shelf preference migration

**Files:**

- Create: `Sources/BarrelMac/Support/ShelfWindowPreferences.swift`
- Create: `Tests/BarrelMacTests/ShelfWindowPreferencesTests.swift`

**Interfaces:**

- Produces: `ShelfWindowPreferences.migrate(_:)` and the shared preference key
  constants used by the panel and Settings.
- Consumes: `UserDefaults`.

- [ ] **Step 1: Write failing migration tests**

```swift
import XCTest
@testable import BarrelMac

final class ShelfWindowPreferencesTests: XCTestCase {
  private func isolatedDefaults() -> UserDefaults {
    let suiteName = "ShelfWindowPreferencesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    addTeardownBlock {
      defaults.removePersistentDomain(forName: suiteName)
    }
    return defaults
  }

  func testFirstMigrationSetsRecommendedBehavior() {
    let defaults = isolatedDefaults()
    defaults.set("right", forKey: ShelfWindowPreferences.edgeKey)
    defaults.set(false, forKey: ShelfWindowPreferences.autoHideKey)

    ShelfWindowPreferences.migrate(defaults)

    XCTAssertEqual(
      defaults.string(forKey: ShelfWindowPreferences.edgeKey),
      "left"
    )
    XCTAssertTrue(defaults.bool(forKey: ShelfWindowPreferences.autoHideKey))
    XCTAssertEqual(
      defaults.integer(forKey: ShelfWindowPreferences.migrationKey),
      ShelfWindowPreferences.currentVersion
    )
  }

  func testCompletedMigrationPreservesLaterUserChoices() {
    let defaults = isolatedDefaults()
    ShelfWindowPreferences.migrate(defaults)
    defaults.set("right", forKey: ShelfWindowPreferences.edgeKey)
    defaults.set(false, forKey: ShelfWindowPreferences.autoHideKey)

    ShelfWindowPreferences.migrate(defaults)

    XCTAssertEqual(
      defaults.string(forKey: ShelfWindowPreferences.edgeKey),
      "right"
    )
    XCTAssertFalse(defaults.bool(forKey: ShelfWindowPreferences.autoHideKey))
  }
}
```

Create each isolated suite with a UUID name and remove its persistent domain in
`tearDown` or a `defer` block.

- [ ] **Step 2: Run the tests to verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ShelfWindowPreferencesTests
```

Expected: compilation fails because `ShelfWindowPreferences` does not exist.

- [ ] **Step 3: Implement the versioned migration**

```swift
enum ShelfWindowPreferences {
  static let edgeKey = "ShelfEdge"
  static let autoHideKey = "AutoHideShelf"
  static let migrationKey = "ShelfWindowBehaviorVersion"
  static let currentVersion = 1

  static func migrate(_ defaults: UserDefaults = .standard) {
    guard defaults.integer(forKey: migrationKey) < currentVersion else {
      return
    }
    defaults.set(ShelfEdge.left.rawValue, forKey: edgeKey)
    defaults.set(true, forKey: autoHideKey)
    defaults.set(currentVersion, forKey: migrationKey)
  }
}
```

- [ ] **Step 4: Run focused and full tests**

Run the migration filter, then `swift test`. Expected: both migration tests and
the complete suite pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/BarrelMac/Support/ShelfWindowPreferences.swift \
  Tests/BarrelMacTests/ShelfWindowPreferencesTests.swift
git commit -m "feat: migrate edge shelf preferences"
```

---

### Task 3: Non-activating panel and event controller

**Files:**

- Create: `Sources/BarrelMac/Support/ShelfPanelController.swift`
- Create: `Sources/BarrelMac/Support/EdgeShelfController.swift`
- Create: `Tests/BarrelMacTests/ShelfPanelControllerTests.swift`

**Interfaces:**

- Consumes: `ShelfStore`, `ContentView`, `EdgeShelfStateMachine`,
  `ShelfPanelLayout`, `ShelfWindowPreferences`, and `UserDefaults`.
- Produces: `ShelfPanelController.start()`, `stop()`, `showShelf()`, and
  `setDropTargeted(_:)`.

- [ ] **Step 1: Write failing panel-configuration tests**

On the main actor, create a panel through a testable factory and assert:

```swift
@MainActor
func testPanelIsNonActivatingAndAvailableInFullScreenSpaces() {
  let panel = ShelfPanelController.makePanel(contentView: NSView())

  XCTAssertTrue(panel.styleMask.contains(.borderless))
  XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
  XCTAssertEqual(panel.level, .statusBar)
  XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
  XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
  XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
  XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
  XCTAssertTrue(panel.hidesOnDeactivate == false)
  XCTAssertEqual(panel.contentView?.frame.size, NSSize(width: 280, height: 480))
}
```

Also assert that `ShelfPanel.canBecomeKey` is true and `canBecomeMain` is false.

- [ ] **Step 2: Run the test to verify RED**

Run `swift test --filter ShelfPanelControllerTests`. Expected: compilation
fails because the panel controller does not exist.

- [ ] **Step 3: Implement the panel factory and public controller**

Create this ownership boundary:

```swift
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
    panel.contentView = NSHostingView(
      rootView: ContentView(
        store: store,
        onDropTargetChange: { [weak edgeController] targeted in
          edgeController?.setDropTargeted(targeted)
        }
      )
    )
    self.panel = panel
    self.edgeController = edgeController
  }

  static func makePanel(contentView: NSView) -> ShelfPanel
  func start() { edgeController.start() }
  func stop() { edgeController.stop() }
  func showShelf() { edgeController.showExplicitly() }
  func setDropTargeted(_ targeted: Bool) {
    edgeController.setDropTargeted(targeted)
  }
}
```

The factory creates a 280-by-480 panel with `.borderless` and
`.nonactivatingPanel`, level `.statusBar`, clear background, shadow, no title,
`isFloatingPanel = true`, `becomesKeyOnlyIfNeeded = true`,
`hidesOnDeactivate = false`, and the four collection behaviors asserted above.

- [ ] **Step 4: Implement event monitoring and delayed effects**

`EdgeShelfController` must own exactly one local monitor, one global monitor,
screen and Space observers, one reveal work item, and one hide work item.

```swift
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

  init(panel: NSPanel, defaults: UserDefaults)
  func start()
  func stop()
  func showExplicitly()
  func setDropTargeted(_ targeted: Bool)
}
```

Monitor `.mouseMoved`, `.leftMouseDragged`, and `.leftMouseUp` locally and
globally. Dispatch global callbacks onto the main actor. For each event:

1. Resolve the display containing `NSEvent.mouseLocation`.
2. On drag, lock only when the panel is already shown, the pointer is inside
   it, or the pointer is in the edge activation zone.
3. On mouse-up, end drag lock with the current panel containment result.
4. Otherwise, send edge or panel enter/exit events to the state machine.
5. Apply returned effects and cancel obsolete delayed work before scheduling
   new work.

Use 0.10-second reveal and 0.25-second hide work items. `.show` positions the
panel on the pointer's display and calls `orderFrontRegardless()`. `.hide`
moves it completely outside that display. Do not call `NSApp.activate`.

Observe `NSApplication.didChangeScreenParametersNotification` and
`NSWorkspace.activeSpaceDidChangeNotification`. Re-resolve the display,
cancel the current panel animation, apply the latest frame, and re-order a
shown panel.

- [ ] **Step 5: Run focused tests and build**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ShelfPanelControllerTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

Expected: panel tests pass and the executable builds.

- [ ] **Step 6: Commit**

```bash
git add Sources/BarrelMac/Support/ShelfPanelController.swift \
  Sources/BarrelMac/Support/EdgeShelfController.swift \
  Tests/BarrelMacTests/ShelfPanelControllerTests.swift
git commit -m "feat: add full-screen shelf panel"
```

---

### Task 4: App lifecycle, explicit reveal, and drag integration

**Files:**

- Modify: `Sources/BarrelMac/App/BarrelMacApp.swift`
- Modify: `Sources/BarrelMac/Views/ContentView.swift`
- Delete: `Sources/BarrelMac/Support/WindowConfigurator.swift`
- Test: `Tests/BarrelMacTests/EdgeShelfModelTests.swift`

**Interfaces:**

- Consumes: `ShelfPanelController` from Task 3.
- Produces: one shared `ShelfStore` owned by `AppDelegate`; all explicit reveal
  paths call `AppDelegate.showShelf()` and the custom panel.

- [ ] **Step 1: Add a failing explicit-reveal transition test**

Extend `EdgeShelfModelTests` to prove explicit reveal cancels both possible
delays and remains shown until a later pointer-exit event:

```swift
func testExplicitShowCancelsPendingHideAndShowsPanel() {
  var machine = EdgeShelfStateMachine(phase: .hidePending)

  XCTAssertEqual(machine.handle(.explicitShow), [.cancelHide, .show])
  XCTAssertEqual(machine.phase, .shown)
}
```

Run the focused test and confirm it fails if Task 1 did not already guarantee
this exact effect order. Adjust only the state machine to make the test pass.

- [ ] **Step 2: Move shared shelf ownership into the app delegate**

Change `AppDelegate` to own:

```swift
let store = ShelfStore()
private var shelfPanelController: ShelfPanelController?
```

In `applicationDidFinishLaunching`:

```swift
ShelfWindowPreferences.migrate()
let controller = ShelfPanelController(store: store)
shelfPanelController = controller
controller.start()
```

In `applicationWillTerminate`, stop and clear the panel controller. Remove
`configureOpenFileHandler`, the weak store, and pending selection. File-open,
repository-change, and selection handlers use the always-available delegate
store directly.

Make `showShelf()` internal and call only:

```swift
shelfPanelController?.showShelf()
```

Do not activate the application or search `NSApp.windows`.

- [ ] **Step 3: Remove the normal shelf WindowGroup**

Delete the `WindowGroup("Barrel", id: "main")` scene. Keep `MenuBarExtra` and
`Settings`. Extract menu content into a small view with
`@ObservedObject var store: ShelfStore` so counts and button states keep
updating. The **Show Shelf** action calls `appDelegate.showShelf()`.

Pass `appDelegate.store` to Settings and menu content. Keep `SyncController`
and `GlobalHotKeyController` ownership unchanged.

- [ ] **Step 4: Connect SwiftUI drop targeting to the panel controller**

Give `ContentView` an explicit initializer and callback:

```swift
struct ContentView: View {
  @ObservedObject var store: ShelfStore
  let onDropTargetChange: (Bool) -> Void

  init(
    store: ShelfStore,
    onDropTargetChange: @escaping (Bool) -> Void = { _ in }
  ) {
    self.store = store
    self.onDropTargetChange = onDropTargetChange
  }
}
```

Remove `.background(WindowConfigurator(...))`. Add:

```swift
.onChange(of: isDropTargeted) {
  onDropTargetChange(isDropTargeted)
}
.onDisappear {
  onDropTargetChange(false)
}
```

Keep the existing `.onDrop` import path and every `ShelfTile.onDrag` provider.
Update the preview to 280 by 480 points.

- [ ] **Step 5: Delete the obsolete configurator and scan reveal paths**

Delete `WindowConfigurator.swift`. Run:

```bash
rg -n 'WindowConfigurator|NSApp\.activate|makeKeyAndOrderFront|NSApp\.windows' \
  Sources/BarrelMac
```

Expected: no shelf reveal path uses the removed configurator, application
activation, or arbitrary window lookup. Settings may continue to use normal
SwiftUI window behavior without any explicit shelf lookup.

- [ ] **Step 6: Run tests and build**

Run the focused edge and panel tests, the full suite, and a debug build.
Expected: all tests pass and `BarrelMac` builds without a `WindowGroup` shelf.

- [ ] **Step 7: Commit**

```bash
git add Sources/BarrelMac/App/BarrelMacApp.swift \
  Sources/BarrelMac/Views/ContentView.swift \
  Sources/BarrelMac/Support/WindowConfigurator.swift \
  Tests/BarrelMacTests/EdgeShelfModelTests.swift
git commit -m "feat: route shelf through edge panel"
```

---

### Task 5: Documentation and acceptance verification

**Files:**

- Modify: `README.md`
- Modify: `docs/privacy.md` only if focus or event-monitor wording belongs in
  the privacy disclosure after implementation review.

**Interfaces:**

- Consumes: completed panel behavior from Tasks 1 through 4.
- Produces: user-facing operating instructions and final verification evidence.

- [ ] **Step 1: Update user-facing shelf instructions**

Document that Barrel hides completely at the selected display edge, follows the
pointer across displays and Spaces, appears over full-screen apps, does not take
focus on hover, and remains open throughout drag operations. Keep the existing
right-edge and persistent settings documented as optional overrides.

- [ ] **Step 2: Review privacy implications**

Confirm the implementation uses only AppKit local/global mouse event monitors
and does not record coordinates or request Accessibility privileges. If that is
true, add one sentence to `docs/privacy.md` explaining that pointer events are
used transiently for edge reveal and are not stored. If implementation requires
a permission, document the exact permission and fallback behavior instead.

- [ ] **Step 3: Run automated acceptance**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
./script/build_and_run.sh --verify
bash -n script/build_and_run.sh
plutil -lint dist/BarrelMac.app/Contents/Info.plist
git diff --check
```

Expected: the full suite passes, the release build succeeds, the staged bundle
launches and terminates its own PID, shell and property-list checks pass, and
the diff has no whitespace errors.

- [ ] **Step 4: Run prohibited-pattern checks**

```bash
! rg -n 'scheduledTimer|NSImage\(contentsOf:' Sources/BarrelMac
! rg -n -i 'iOS|iPhone|iPad|UIKit' README.md Sources Package.swift
! rg -n 'WindowConfigurator' Sources Tests
```

Expected: all commands return no matches.

- [ ] **Step 5: Perform manual macOS acceptance**

Use two displays when available:

1. Hover at the left edge of display one and confirm a delayed reveal.
2. Leave and confirm a delayed, flicker-free hide with no visible tab.
3. Repeat on display two and confirm the same panel follows the pointer.
4. Enter a full-screen application and repeat the reveal.
5. Confirm the foreground app keeps keyboard focus during hover reveal.
6. Drag a file from Finder into Barrel and confirm the panel stays open.
7. Drag the stored file from Barrel into another app and confirm it stays open
   until mouse-up.
8. Trigger the global shortcut and menu-bar command on each display.
9. Change to the right edge and persistent mode, relaunch, and confirm the
   user's post-migration settings remain unchanged.

Record unavailable hardware or full-screen automation limitations explicitly;
do not claim those paths passed without interactive evidence.

- [ ] **Step 6: Commit documentation**

```bash
git add README.md docs/privacy.md
git commit -m "docs: explain full-screen edge shelf"
```

- [ ] **Step 7: Request final code review**

Review the complete range from the commit before Task 1 through `HEAD`. Fix all
Critical and Important findings, rerun the automated acceptance commands, and
leave the working tree clean.
