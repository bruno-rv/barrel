# Quick Send Task 7 Report

## Status

Complete. Quick Send now has a retained, activating panel with immediate search
focus, compact grouped results, keyboard operation, layered Escape handling,
and idle-only outside dismissal.

## Implementation

- Added one reusable key-capable `NSPanel` that is intentionally not a
  nonactivating shelf panel and cannot become the app's main window.
- Added injectable application-activation and responder-focus seams. Every
  presentation activates Barrel, centers the stored panel on the display under
  the pointer, refreshes Quick Send, brings the same panel forward, and
  schedules the registered `NSSearchField` as first responder.
- Added a compact native SwiftUI picker with search, Finder Automation guidance,
  grouped results, selection highlighting, progress and inline-error states,
  secondary actions, and accessibility labels/traits.
- Forwarded Up, Down, Return, Command-Return, and Escape from the native search
  field to the store-backed model. Escape closes the model's secondary layer
  before dismissing the panel and is blocked while an operation is running.
- Dismissed on resign-key only while idle, so in-flight imports, exports, and
  Undo operations are not hidden by an outside click.
- Retained the Quick Send controller alongside the existing shelf controller,
  observed `.showBarrelQuickSend`, and ordered Quick Send out during termination
  without changing shelf notification, intent, or lifecycle behavior.

## TDD evidence

The corrected initial focused RED run failed to compile because
`QuickSendPanelController`, `QuickSendActivating`, and
`QuickSendFocusScheduling` did not exist.

Fresh final verification:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter QuickSendPanelControllerTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter BarrelMacTests
git diff --check
```

Results: 4 panel-controller tests and 108 BarrelMac XCTest tests passed with
zero failures; all 33 Swift Testing tests selected with BarrelMac also passed.
`git diff --check` passed.

## Concerns

Finder Automation consent and actual first-responder behavior across process
activation still require the plan's manual bundled-app check; unit tests cover
the injected activation and focus scheduling seams.

## Re-review fix — destination and action routing

- Escape now returns an explicit `blocked`, `closedLayer`, or `dismissPanel`
  outcome. The view and panel controller dismiss only for `dismissPanel`; the
  controller integration test covers closing a destination layer before
  ordering out the panel.
- Activating a temporary file/image opens a destination layer and does not
  export. Keyboard Return, double-click, the visible activation button, and the
  accessibility activation action all route the exact chosen destination.
- Destination exports retain the originating item ID even if selection changes.
  A real store-backed multi-destination test chooses the older folder and
  verifies that no file is written to the newer folder.
- Temporary Open and Reveal actions use item-ID ShelfStore entry points and
  remain bound to the result that opened the action layer. History actions keep
  the same captured-result behavior.
- Rows use single-click selection, double-click activation, and contained
  accessibility children so their Open, Reveal, and primary buttons remain
  independently interactive.

TDD red evidence: the first focused run failed to compile on the absent Escape
outcome, destination-layer mode/results, export dispatch seam, and captured item
action APIs. After the first implementation pass, the legacy scoped-access test
failed because it still expected automatic export; it was converted to the
required choose-destination command path.

Fresh verification:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'QuickSend(Model|PanelController|Action)Tests'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter BarrelMacTests
git diff --check
```

Results: 38 focused Quick Send tests passed; the full BarrelMac run passed 108
XCTest tests and 38 Swift Testing tests with zero failures; `git diff --check`
passed.
