# Quick Send Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second global shortcut that opens a keyboard-focused Quick Send
panel for Finder selection import, shelf and History search, recent-destination
export, and validated Undo.

**Architecture:** Keep repository state authoritative in `ShelfStore` and add a
focused Quick Send presentation model, a dedicated activating panel, and a
protocol-backed Finder Apple Events reader. Persist destination-directory
bookmarks only in local History, register the two Carbon shortcuts
independently, and reuse the existing crash-safe export journal and Undo
transactions.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Carbon, Apple Events, Foundation,
CryptoKit, XCTest, macOS 14.

## Global Constraints

- Keep the existing configurable shelf shortcut unchanged.
- Add a second independently configurable Quick Send shortcut.
- Use a dedicated activating, keyboard-focusable panel; do not reuse the edge
  shelf's nonactivating panel.
- Request Finder Automation only when Quick Send opens.
- Never request Accessibility permission or synthesize copy commands.
- Keep History and recent destinations within the existing 24-hour window.
- Persist destination-directory bookmarks locally; never add them to CloudKit
  or `SyncRecord`.
- Import copies files and never removes or modifies Finder originals.
- Export only file and image items; keep text, link, and stack actions limited
  to their existing valid behavior.
- Preserve exact filenames and fail on collision without overwrite or suffix.
- Reuse existing import, export-journal, pending-recovery, overlay, History,
  and Undo rules.
- Add no third-party dependency and no configurable ranking preference.

---

## File structure

- Modify `Sources/BarrelCore/Models/HistoryEvent.swift` for a migration-safe
  destination-directory bookmark.
- Modify `Sources/BarrelCore/Storage/RepositoryTypes.swift` and
  `ShelfRepository.swift` to create and retain that bookmark locally.
- Create `Sources/BarrelMac/Services/RecentDestinationResolver.swift` for
  bookmark resolution, deduplication, and scoped destination access.
- Modify `Sources/BarrelMac/Services/GlobalHotKeyController.swift`,
  `Sources/BarrelMac/App/BarrelEnvironment.swift`, and Settings for two
  independent Carbon registrations.
- Create `Sources/BarrelMac/Services/FinderSelectionReader.swift` for Apple
  Events execution and descriptor parsing.
- Create `Sources/BarrelMac/Models/QuickSendResult.swift` and
  `Sources/BarrelMac/Services/QuickSendModel.swift` for ranking and commands.
- Extend `Sources/BarrelMac/Services/ShelfStore.swift` with result-returning
  action seams shared by Quick Send and existing views.
- Create `Sources/BarrelMac/Support/QuickSendPanelController.swift` and
  `Sources/BarrelMac/Views/QuickSendView.swift` for the activating panel.
- Modify app wiring, bundle metadata, README, and privacy documentation.

### Task 1: Persist destination-directory bookmarks

**Files:**

- Modify: `Sources/BarrelCore/Models/HistoryEvent.swift`
- Modify: `Sources/BarrelCore/Storage/RepositoryTypes.swift`
- Modify: `Sources/BarrelCore/Storage/ShelfRepository.swift`
- Test: `Tests/BarrelCoreTests/HistoryRepositoryTests.swift`

**Interfaces:**

- Produces: `HistoryEvent.destinationDirectoryBookmark: Data?` and
  `RepositoryConfiguration.directoryBookmarkCreator`.
- Preserves: existing History JSON, local manifest migration, `ShelfItem`,
  `SyncRecord`, export journal, and Undo behavior.

- [ ] **Step 1: Write failing bookmark persistence tests**

Add tests that inject deterministic bytes and assert export, cold reload, and
Undo reverse-event retention:

```swift
let bookmark = Data("directory-bookmark".utf8)
let repository = ShelfRepository(configuration: configuration(
    root: root,
    directoryBookmarkCreator: { _ in bookmark }
))
let event = try await repository.export(
    itemID: item.id,
    to: destination,
    fileName: item.fileName
)
#expect(event.destinationDirectoryBookmark == bookmark)
#expect(try await repository.historySnapshot().first?
    .destinationDirectoryBookmark == bookmark)
```

Add a legacy JSON fixture without the key and assert the decoded property is
`nil`. Assert `syncRecords()` before and after export remains equal.

- [ ] **Step 2: Verify the tests fail for the missing field**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter HistoryRepositoryTests
```

Expected: compile failures because the bookmark field and configuration
injection do not exist.

- [ ] **Step 3: Add the migration-safe model and configuration seam**

Add an optional property and defaulted initializer argument:

```swift
public var destinationDirectoryBookmark: Data?

public init(
    // existing arguments
    destinationDirectoryBookmark: Data? = nil
) {
    self.destinationDirectoryBookmark = destinationDirectoryBookmark
}
```

Add:

```swift
public typealias DirectoryBookmarkCreator = @Sendable (URL) -> Data?

public let directoryBookmarkCreator: DirectoryBookmarkCreator
```

The production default attempts a `.withSecurityScope` bookmark and returns
`nil` when the current unsandboxed environment does not issue one.

- [ ] **Step 4: Populate export and Undo events**

Create the bookmark from the standardized destination directory while its
scope is active. Copy both file and directory bookmarks into the reverse Undo
event. Do not add either bookmark to `SyncRecord`.

- [ ] **Step 5: Run Core regressions and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter HistoryRepositoryTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ShelfRepositoryTests
git add Sources/BarrelCore/Models/HistoryEvent.swift \
  Sources/BarrelCore/Storage/RepositoryTypes.swift \
  Sources/BarrelCore/Storage/ShelfRepository.swift \
  Tests/BarrelCoreTests/HistoryRepositoryTests.swift
git commit -m "feat: persist recent destination bookmarks"
```

Expected: both selections pass and the commit contains no sync-model change.

### Task 2: Resolve recent destinations

**Files:**

- Create: `Sources/BarrelMac/Services/RecentDestinationResolver.swift`
- Create: `Tests/BarrelMacTests/RecentDestinationResolverTests.swift`

**Interfaces:**

- Consumes: `HistoryEvent.destinationDirectoryBookmark` from Task 1.
- Produces: `RecentDestination`, `RecentDestinationResolving`, and scoped
  `withAccess(to:operation:)` for destination export.

- [ ] **Step 1: Write failing resolution and deduplication tests**

Define the expected API in tests:

```swift
let resolver = RecentDestinationResolver(
    resolveBookmark: { data in bookmarkURLs[data] },
    fileExists: { existingURLs.contains($0.standardizedFileURL) }
)
let destinations = resolver.destinations(from: events)
#expect(destinations.map(\.url) == [desktop, documents])
#expect(destinations.first?.lastUsedAt == newest.timestamp)
```

Cover bookmark-first resolution, legacy parent-directory fallback,
standardized-path deduplication, newest event winning, reverse events, missing
URLs, and empty History.

- [ ] **Step 2: Verify the resolver tests fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter RecentDestinationResolverTests
```

Expected: compile failure because the resolver types do not exist.

- [ ] **Step 3: Implement the focused resolver**

Define:

```swift
struct RecentDestination: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL
    let bookmark: Data?
    let lastUsedAt: Date
}

protocol RecentDestinationResolving: Sendable {
    func destinations(from events: [HistoryEvent]) -> [RecentDestination]
}
```

Iterate newest-first export events, resolve the directory bookmark first, fall
back to `destinationURL.deletingLastPathComponent()`, standardize the URL,
ignore nonexistent directories, and keep the first path occurrence.

- [ ] **Step 4: Add scoped access around asynchronous export**

Implement a helper that balances `startAccessingSecurityScopedResource()` and
`stopAccessingSecurityScopedResource()` across an awaited operation. Add a test
double proving scope remains active until the asynchronous export returns.

- [ ] **Step 5: Verify and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter RecentDestinationResolverTests
git add Sources/BarrelMac/Services/RecentDestinationResolver.swift \
  Tests/BarrelMacTests/RecentDestinationResolverTests.swift
git commit -m "feat: derive recent export destinations"
```

### Task 3: Register and dispatch two global shortcuts

**Files:**

- Modify: `Sources/BarrelMac/Services/GlobalHotKeyController.swift`
- Modify: `Sources/BarrelMac/App/BarrelEnvironment.swift`
- Modify: `Sources/BarrelMac/Views/SettingsView.swift`
- Create: `Tests/BarrelMacTests/GlobalHotKeyControllerTests.swift`

**Interfaces:**

- Produces: `GlobalHotKeyAction`, independent registrations/errors, and
  `Notification.Name.showBarrelQuickSend`.
- Preserves: existing shelf shortcut defaults and `.showBarrelShelf` behavior.

- [ ] **Step 1: Write failing dual-registration tests**

Use an injected registration wrapper and assert:

```swift
#expect(registrar.registered.map(\.action) == [.shelf, .quickSend])
controller.handleHotKeyID(GlobalHotKeyAction.shelf.rawValue)
#expect(notifications == [.showBarrelShelf])
controller.handleHotKeyID(GlobalHotKeyAction.quickSend.rawValue)
#expect(notifications == [.showBarrelShelf, .showBarrelQuickSend])
```

Cover independent enablement, same-choice conflict, invalid saved values, one
OS registration failure, reconfiguration cleanup, and IDs `1` and `2`.

- [ ] **Step 2: Verify the tests fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GlobalHotKeyControllerTests
```

Expected: failure because only one Carbon registration exists.

- [ ] **Step 3: Implement independent action registrations**

Define:

```swift
enum GlobalHotKeyAction: UInt32, CaseIterable, Sendable {
    case shelf = 1
    case quickSend = 2
}
```

Store one registration token per action. Validate raw choices without silent
fallback. Shelf wins a same-choice conflict; Quick Send records the explicit
conflict error. Failure of either OS registration leaves the other untouched.

- [ ] **Step 4: Add defaults and Settings controls**

Register:

```swift
"QuickSendHotKeyEnabled": true
"QuickSendHotKeyChoice": "control-shift-space"
```

Add the second enable toggle, picker, and action-specific error. Keep the shelf
controls and saved values unchanged.

- [ ] **Step 5: Verify and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GlobalHotKeyControllerTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ShelfWindowPreferencesTests
git add Sources/BarrelMac/Services/GlobalHotKeyController.swift \
  Sources/BarrelMac/App/BarrelEnvironment.swift \
  Sources/BarrelMac/Views/SettingsView.swift \
  Tests/BarrelMacTests/GlobalHotKeyControllerTests.swift
git commit -m "feat: add Quick Send global shortcut"
```

### Task 4: Read Finder selection with Apple Events

**Files:**

- Create: `Sources/BarrelMac/Services/FinderSelectionReader.swift`
- Create: `Tests/BarrelMacTests/FinderSelectionReaderTests.swift`

**Interfaces:**

- Produces: `FinderSelectionState`, `FinderSelectionReading`, and an injectable
  Apple Events executor/descriptor parser.
- Preserves: no Accessibility permission and no synthetic keyboard input.

- [ ] **Step 1: Write failing state and parser tests**

Use fake frontmost-app and Apple Events executors:

```swift
let reader = FinderSelectionReader(
    frontmostBundleID: { "com.apple.finder" },
    execute: { .fileURLs([firstURL, secondURL]) }
)
#expect(await reader.readSelection() == .selection([firstURL, secondURL]))
```

Cover ordered file/folder URLs, empty list, Finder not frontmost, error `-1743`,
Finder unavailable, and malformed/non-list descriptors.

- [ ] **Step 2: Verify the tests fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter FinderSelectionReaderTests
```

Expected: compile failure because the reader does not exist.

- [ ] **Step 3: Implement the protocol and pure descriptor parsing**

Define:

```swift
enum FinderSelectionState: Equatable, Sendable {
    case selection([URL])
    case empty
    case unavailable
    case permissionDenied
}

protocol FinderSelectionReading: Sendable {
    func readSelection() async -> FinderSelectionState
}
```

Check Finder is frontmost before executing the event. Parse only ordered file
URL descriptors, map `-1743` to permission denial, and map malformed responses
to unavailable. Perform Apple Events work off the main actor.

- [ ] **Step 4: Verify and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter FinderSelectionReaderTests
git add Sources/BarrelMac/Services/FinderSelectionReader.swift \
  Tests/BarrelMacTests/FinderSelectionReaderTests.swift
git commit -m "feat: read Finder selection for Quick Send"
```

### Task 5: Build ranked Quick Send state

**Files:**

- Create: `Sources/BarrelMac/Models/QuickSendResult.swift`
- Create: `Sources/BarrelMac/Services/QuickSendModel.swift`
- Create: `Tests/BarrelMacTests/QuickSendModelTests.swift`

**Interfaces:**

- Consumes: Finder state from Task 4, `ShelfStore.items`, History, and recent
  destinations from Task 2.
- Produces: stable ranked results, selection, keyboard commands, secondary
  destination/action state, and permission/error presentation.

- [ ] **Step 1: Write failing ranking tests**

Assert the exact group order and match ranking:

```swift
model.query = "rep"
await model.refresh()
#expect(model.results.map(\.group) == [
    .finderSelection, .undoLatest, .temporary, .history, .destination,
])
#expect(model.resultsInGroup(.temporary).first?.title == "Report.pdf")
```

Cover prefix before substring, source recency ties, stable IDs across async
Finder refresh, empty-query content, item kind/origin tokens, file/image send
eligibility, text/link/stack search-only behavior, latest eligible Undo, and
informational reverse events.

- [ ] **Step 2: Write failing keyboard-state tests**

Cover Up/Down wrapping, Return primary dispatch, Command-Return secondary
state, Escape closing secondary state before the panel, permission denial
disabling only Finder import, and operation-running dismissal guards.

- [ ] **Step 3: Verify the model tests fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter QuickSendModelTests
```

Expected: compile failure because the model and result types do not exist.

- [ ] **Step 4: Implement result types and pure ranking**

Define stable result IDs by semantic identity, not array offset. Normalize query
tokens using localized case/diacritic-insensitive comparison. Group first,
prefix-match before substring-match, then keep the existing source recency.

- [ ] **Step 5: Implement keyboard and permission state**

Keep query, selected result ID, Finder state, secondary mode, inline error, and
operation-running state in `QuickSendModel`. Route actions through injected
closures; Task 6 connects those closures to `ShelfStore`.

- [ ] **Step 6: Verify and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter QuickSendModelTests
git add Sources/BarrelMac/Models/QuickSendResult.swift \
  Sources/BarrelMac/Services/QuickSendModel.swift \
  Tests/BarrelMacTests/QuickSendModelTests.swift
git commit -m "feat: rank Quick Send commands"
```

### Task 6: Route Quick Send actions through ShelfStore

**Files:**

- Modify: `Sources/BarrelMac/Services/ShelfStore.swift`
- Modify: `Sources/BarrelMac/Services/QuickSendModel.swift`
- Create: `Tests/BarrelMacTests/QuickSendActionTests.swift`
- Modify: `Tests/BarrelMacTests/ShelfStoreHistoryTests.swift`

**Interfaces:**

- Consumes: Task 5 action requests and Task 2 scoped destinations.
- Produces: result-returning import, export, Undo, open, and reveal actions
  shared by Quick Send and existing UI wrappers.

- [ ] **Step 1: Write failing action-routing tests**

Cover full and partial Finder import, successful export, exact-name collision,
pending-recovery refresh/blocking, successful Undo, cleanup-warning Undo,
History open/reveal, and tombstone-overlay re-export.

```swift
let outcome = await store.importURLsForQuickSend([goodURL, folderURL])
#expect(outcome.importedCount == 1)
#expect(outcome.failures.count == 1)
```

- [ ] **Step 2: Verify the action tests fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter QuickSendActionTests
```

Expected: compile failure because result-returning store seams do not exist.

- [ ] **Step 3: Extract shared result-returning operations**

Keep current fire-and-forget UI methods as wrappers. Add async operations that
return import outcomes, throw export errors, and return Undo status. Preserve
the existing success-only refresh and pending-recovery immediate refresh.

- [ ] **Step 4: Connect QuickSendModel actions**

On successful one-shot import, export, or Undo, refresh results and request
panel dismissal. On failure, preserve query/selection and set inline error.
Keep scoped destination access active across awaited export.

- [ ] **Step 5: Verify store and action regressions, then commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter QuickSendActionTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ShelfStoreHistoryTests
git add Sources/BarrelMac/Services/ShelfStore.swift \
  Sources/BarrelMac/Services/QuickSendModel.swift \
  Tests/BarrelMacTests/QuickSendActionTests.swift \
  Tests/BarrelMacTests/ShelfStoreHistoryTests.swift
git commit -m "feat: route Quick Send actions"
```

### Task 7: Add the activating panel and keyboard interface

**Files:**

- Create: `Sources/BarrelMac/Support/QuickSendPanelController.swift`
- Create: `Sources/BarrelMac/Views/QuickSendView.swift`
- Modify: `Sources/BarrelMac/App/BarrelMacApp.swift`
- Create: `Tests/BarrelMacTests/QuickSendPanelControllerTests.swift`

**Interfaces:**

- Consumes: Quick Send model/actions and `.showBarrelQuickSend`.
- Produces: one reusable activating panel, scheduled search focus, keyboard
  command forwarding, layered Escape, and idle-only outside dismissal.

- [ ] **Step 1: Write failing panel lifecycle tests**

Assert key-capable configuration, active-screen centering, single identity,
one activation per presentation, and scheduled focus:

```swift
controller.show()
let firstPanel = controller.panelForTesting
controller.show()
#expect(controller.panelForTesting === firstPanel)
#expect(activator.activationCount == 2)
#expect(focusScheduler.lastResponder === searchField)
```

Cover `canBecomeKey == true`, `canBecomeMain == false`, absence of
`.nonactivatingPanel`, Escape ordering, and resign-key dismissal only while
idle.

- [ ] **Step 2: Verify the panel tests fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter QuickSendPanelControllerTests
```

Expected: compile failure because the controller does not exist.

- [ ] **Step 3: Implement the activating panel controller**

Define injectable activation and focus scheduling protocols. Create one stored
panel and one hosting view. `show()` refreshes the model, activates the app,
centers on the pointer/active screen, calls `makeKeyAndOrderFront`, and focuses
the registered `NSSearchField` after layout.

- [ ] **Step 4: Build the compact SwiftUI picker**

Render search, Finder permission/import status, grouped results, selected-row
highlight, inline error, and secondary destination/actions. Provide accessible
labels and keyboard handlers for Up, Down, Return, Command-Return, and Escape.
Use an AppKit search-field wrapper to report the responder to the controller.

- [ ] **Step 5: Wire app lifecycle and notification**

Retain one controller beside the existing shelf controller. Observe
`.showBarrelQuickSend`, leave `.showBarrelShelf` and intents unchanged, and
order the Quick Send panel out during app termination.

- [ ] **Step 6: Verify and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter QuickSendPanelControllerTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter BarrelMacTests
git add Sources/BarrelMac/Support/QuickSendPanelController.swift \
  Sources/BarrelMac/Views/QuickSendView.swift \
  Sources/BarrelMac/App/BarrelMacApp.swift \
  Tests/BarrelMacTests/QuickSendPanelControllerTests.swift
git commit -m "feat: add Quick Send panel"
```

### Task 8: Bundle metadata, documentation, and final verification

**Files:**

- Modify: `script/build_and_run.sh`
- Modify: `README.md`
- Modify: `docs/privacy.md`
- Modify only scoped source/test files when verification proves a regression.

**Interfaces:**

- Consumes: the completed Quick Send feature.
- Produces: Automation usage metadata, user documentation, and fresh release
  evidence.

- [ ] **Step 1: Add Automation usage metadata**

Generate this key in the app's `Info.plist`:

```xml
<key>NSAppleEventsUsageDescription</key>
<string>Barrel uses Finder Automation only when Quick Send opens to read the files you currently selected.</string>
```

- [ ] **Step 2: Update README and privacy documentation**

Document the second shortcut, Finder permission timing, keyboard controls,
24-hour destinations, exact-name collision failure, and that selection data is
neither monitored continuously nor transmitted.

- [ ] **Step 3: Run the full automated suite**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: every test passes with zero unexpected warnings.

- [ ] **Step 4: Verify the bundle and plist**

```bash
make verify
/usr/libexec/PlistBuddy -c \
  'Print :NSAppleEventsUsageDescription' \
  dist/BarrelMac.app/Contents/Info.plist
```

Expected: the app builds and launches, and the printed string exactly matches
Step 1.

- [ ] **Step 5: Run the manual macOS matrix**

Verify both shortcuts independently, initial search focus, Finder consent and
denial, empty and mixed selection, partial folder failure, prefix ranking,
recent-destination export, collision error, Undo Latest, repeated panel reuse,
Escape, and no regression to edge-shelf activation.

- [ ] **Step 6: Audit the final diff and commit documentation**

```bash
git status --short
git diff --check
git diff --stat eb3a952..HEAD
git add script/build_and_run.sh README.md docs/privacy.md
git commit -m "docs: document Quick Send automation"
```

If verification required a scoped correction, rerun its focused test and the
full suite before including it in a separate correction commit.
