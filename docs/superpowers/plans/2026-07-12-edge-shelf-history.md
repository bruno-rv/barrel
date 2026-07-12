# Edge Shelf Timing and File History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Require a stable three-second edge dwell, keep the shelf visible for
at least three seconds, and add a persistent 24-hour Finder export history with
safe Undo.

**Architecture:** Keep pointer timing in the edge state machine and drive it
with an injectable scheduler. Store shelf items, local exported-item IDs, and
immutable history events in one atomic local manifest; do not synchronize
machine-local paths or bucket state through CloudKit. Use an AppKit
`NSFilePromiseProvider` bridge for filesystem exports and keep copy, collision,
hash verification, retention, and Undo transactions in `BarrelCore`.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Foundation, CryptoKit, Swift Testing,
macOS 14.

## Global Constraints

- The activation area is the full-height, three-pixel extreme-left strip.
- Reveal requires three continuous seconds in the activation strip.
- The visible shelf remains open for at least three seconds.
- History persists locally across restarts and retains events for 86,400
  seconds.
- Import and export copy files; Barrel never changes the original import.
- Export and Undo never overwrite an existing file.
- Undo deletes only a regular file whose path and SHA-256 hash match the event.
- Only filesystem drops create history; non-file items keep their existing drag
  behavior.
- Existing CloudKit records and legacy local manifests remain compatible.
- Add no third-party dependency and no configurable timing or retention UI.

---

## File structure

- Modify `Sources/BarrelMac/Support/EdgeShelfModel.swift`: represent dwell and
  minimum-visible state transitions.
- Modify `Sources/BarrelMac/Support/EdgeShelfController.swift`: schedule model
  effects through an injectable scheduler.
- Create `Sources/BarrelCore/Models/HistoryEvent.swift`: define persistent,
  presentation-ready export and Undo events.
- Modify `Sources/BarrelCore/Storage/RepositoryTypes.swift`: configure retention
  and define typed history errors.
- Modify `Sources/BarrelCore/Storage/ShelfRepository.swift`: migrate the local
  manifest and own export, Undo, pruning, hashing, and cleanup transactions.
- Create `Sources/BarrelMac/Support/FilePromiseDragSource.swift`: bridge a whole
  SwiftUI tile to AppKit file promises.
- Modify `Sources/BarrelMac/Services/ShelfStore.swift`: expose local history,
  export, and Undo operations to the UI.
- Modify `Sources/BarrelMac/Views/ContentView.swift` and
  `Sources/BarrelMac/Views/SidebarView.swift`: render History and preserve
  whole-tile dragging.
- Extend focused Core and Mac test files named in each task.

### Task 1: Deterministic edge timing

**Files:**

- Modify: `Sources/BarrelMac/Support/EdgeShelfModel.swift`
- Modify: `Sources/BarrelMac/Support/EdgeShelfController.swift`
- Test: `Tests/BarrelMacTests/EdgeShelfModelTests.swift`
- Test: `Tests/BarrelMacTests/ShelfPanelControllerTests.swift`

**Interfaces:**

- Produces: `EdgeShelfEvent.minimumVisibilityElapsed`, explicit minimum-hold
  effects, and
  `EdgeShelfScheduler.schedule(after:_:) -> EdgeShelfScheduledTask`.
- Preserves: `ShelfPanelLayout.activationWidth == 3` and existing public
  controller entry points.

- [ ] **Step 1: Add failing state-machine tests**

Add tests equivalent to:

```swift
@Test func exitDuringMinimumVisibilityDefersHide() {
    var machine = EdgeShelfStateMachine()
    _ = machine.handle(.edgeEntered)
    _ = machine.handle(.revealDelayElapsed)
    #expect(machine.phase == .shown)
    #expect(machine.handle(.panelExited) == [.rememberPendingHide])
    #expect(machine.phase == .shown)
    #expect(machine.handle(.minimumVisibilityElapsed) == [.hide])
}

@Test func reentryAndDragCancelDeferredHide() {
    var machine = EdgeShelfStateMachine()
    _ = machine.handle(.edgeEntered)
    _ = machine.handle(.revealDelayElapsed)
    _ = machine.handle(.panelExited)
    #expect(machine.handle(.panelEntered) == [.forgetPendingHide])
    _ = machine.handle(.panelExited)
    #expect(machine.handle(.dragBegan) == [.forgetPendingHide])
    #expect(machine.handle(.minimumVisibilityElapsed).isEmpty)
}
```

Also assert that leaving before the reveal deadline cancels the dwell, drag end
outside after the deadline hides, and `stop()` cancels every pending task.

- [ ] **Step 2: Verify the new timing tests fail**

Run:

```bash
swift test --filter EdgeShelfModelTests
```

Expected: compilation or assertion failures because the minimum-visibility
event/effects and pending-hide state do not exist.

- [ ] **Step 3: Implement the smallest state-machine change**

Add model state for `isMinimumVisibilityElapsed`, `isPointerInsidePanel`, and
`isDragActive`. On reveal, emit `.show` and `.scheduleMinimumVisibility`. On
exit before the deadline, remember pending hide. On deadline, hide only when
the pointer is outside and no drag is active. Reentry clears pending hide.

Define an injectable scheduler:

```swift
@MainActor protocol EdgeShelfScheduledTask { func cancel() }

@MainActor protocol EdgeShelfScheduler {
    @discardableResult
    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any EdgeShelfScheduledTask
}
```

Provide a Dispatch-backed production implementation. Set both production
durations to `3.0`; cancel reveal and minimum tasks in `stop()` and guard stale
callbacks with the existing generation pattern.

- [ ] **Step 4: Replace controller-test sleeps with a fake scheduler**

Add a test scheduler whose `advance(by:)` runs due, uncancelled actions. Assert
no reveal at `2.999`, reveal at `3.0`, no early hide, hide when the minimum
deadline elapses outside, and drag lock precedence.

- [ ] **Step 5: Run focused tests and commit**

```bash
swift test --filter EdgeShelfModelTests
swift test --filter ShelfPanelControllerTests
git add Sources/BarrelMac/Support/EdgeShelfModel.swift \
  Sources/BarrelMac/Support/EdgeShelfController.swift \
  Tests/BarrelMacTests/EdgeShelfModelTests.swift \
  Tests/BarrelMacTests/ShelfPanelControllerTests.swift
git commit -m "feat: stabilize edge shelf timing"
```

Expected: both test selections pass with no three-second wall-clock waits.

### Task 2: Local history manifest and retention

**Files:**

- Create: `Sources/BarrelCore/Models/HistoryEvent.swift`
- Modify: `Sources/BarrelCore/Storage/RepositoryTypes.swift`
- Modify: `Sources/BarrelCore/Storage/ShelfRepository.swift`
- Test: `Tests/BarrelCoreTests/ShelfItemTests.swift`
- Test: `Tests/BarrelCoreTests/HistoryRepositoryTests.swift`

**Interfaces:**

- Produces: `HistoryEvent`, `HistoryEventKind`,
  `ShelfRepository.historySnapshot()`, and a private atomic
  `RepositoryManifest` envelope.
- Preserves: `ShelfItem` and `SyncRecord` wire formats; exported IDs and history
  never enter CloudKit records.

- [ ] **Step 1: Write failing migration and retention tests**

Create fixtures for both the legacy raw `[ShelfItem]` JSON and the new envelope.
Use an injected `TestClock` to assert newest-first order and the exact boundary:

```swift
#expect(try repository.historySnapshot().map(\.id) == [newer.id, older.id])
clock.now = older.timestamp.addingTimeInterval(86_400)
#expect(try repository.historySnapshot().map(\.id) == [newer.id])
```

Assert a legacy manifest loads unchanged and rewrites as an envelope containing
empty `history` and `exportedItemIDs` collections.

- [ ] **Step 2: Verify Core tests fail**

```bash
swift test --filter ShelfItemTests
swift test --filter HistoryRepositoryTests
```

Expected: `HistoryEvent` and `historySnapshot()` are undefined.

- [ ] **Step 3: Add the event types and repository configuration**

Implement:

```swift
public enum HistoryEventKind: String, Codable, Sendable {
    case export
    case undo
}

public struct HistoryEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var itemID: UUID
    public var kind: HistoryEventKind
    public var sourceName: String
    public var destinationName: String
    public var destinationURL: URL?
    public var destinationBookmark: Data?
    public var fileName: String
    public var contentHash: String
    public var timestamp: Date
    public var reversedEventID: UUID?
    public var reversedByEventID: UUID?
}
```

Add `historyRetention: TimeInterval = 86_400` to
`RepositoryConfiguration`. Add typed errors for ineligible, missing, changed,
inaccessible, and nonregular Undo targets.

- [ ] **Step 4: Migrate persistence atomically**

Use a private envelope:

```swift
private struct RepositoryManifest: Codable {
    var items: [ShelfItem]
    var exportedItemIDs: Set<UUID>
    var history: [HistoryEvent]
}
```

Decode the envelope first and fall back to legacy `[ShelfItem]`. Make the one
existing atomic manifest writer encode all three fields. On load and every
history read/write, remove events where `now() - timestamp >= historyRetention`.
When the last event for an exported item expires, remove that item and then run
the existing reference-aware managed-file cleanup. Never use `ShelfFilter` to
decide ownership.

- [ ] **Step 5: Verify migration and retention**

Run:

```bash
swift test --filter ShelfItemTests
swift test --filter HistoryRepositoryTests
swift test --filter ShelfRepositoryTests
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit the schema slice**

```bash
git add Sources/BarrelCore/Models/HistoryEvent.swift \
  Sources/BarrelCore/Storage/RepositoryTypes.swift \
  Sources/BarrelCore/Storage/ShelfRepository.swift \
  Tests/BarrelCoreTests/ShelfItemTests.swift \
  Tests/BarrelCoreTests/HistoryRepositoryTests.swift
git commit -m "feat: persist local export history"
```

### Task 3: Collision-safe export and Undo transactions

**Files:**

- Modify: `Sources/BarrelCore/Storage/ShelfRepository.swift`
- Modify: `Tests/BarrelCoreTests/HistoryRepositoryTests.swift`
- Modify: `Tests/BarrelCoreTests/ShelfRepositoryTests.swift`

**Interfaces:**

- Produces:
  `export(itemID:to:) throws -> HistoryEvent`,
  `undo(historyEventID:) throws -> HistoryEvent`, and
  `temporarySnapshot() throws -> [ShelfItem]`.
- Consumes: the local manifest and 24-hour pruning rules from Task 2.

- [ ] **Step 1: Write failing export transaction tests**

Cover `report.pdf`, `report 2.pdf`, and `report 3.pdf` collision selection,
resolved destination recording, copied-byte/hash equality, temporary-list
removal, cold-reload persistence, and rollback after an injected manifest-write
failure. Assert an exported item sharing a managed file with a live duplicate
does not delete that file. Assert `syncRecords()` is byte-for-byte equivalent
before and after the local export so machine-local state cannot affect another
Mac.

- [ ] **Step 2: Run export tests and observe the expected failure**

```bash
swift test --filter HistoryRepositoryTests/testExport
```

Expected: failure because `export(itemID:to:)` does not exist.

- [ ] **Step 3: Implement export**

Implement a single repository transaction that:

1. Finds a nontrashed, nonexported item and its regular managed file.
2. Chooses an unused basename with a numeric suffix before the extension.
3. Copies without replacement.
4. Verifies the destination is regular and hashes to `contentHash`.
5. Adds the item ID to `exportedItemIDs`, appends an export event, and commits.
6. Removes only the newly created verified copy if commit fails.

Make `temporarySnapshot()` return repository items excluding local exported
IDs, trashed items, and clipboard-only records while leaving `snapshot()`
available for storage and sync internals.

- [ ] **Step 4: Write failing Undo tests**

Test successful deletion/restoration/reverse-event creation; nonlatest,
already-reversed, and expired events; missing, changed, inaccessible, and
nonregular paths; and a manifest-write failure that restores the destination.

- [ ] **Step 5: Run Undo tests and observe the expected failure**

```bash
swift test --filter HistoryRepositoryTests/testUndo
```

Expected: failure because `undo(historyEventID:)` does not exist.

- [ ] **Step 6: Implement reversible Undo**

Resolve bookmark data when present and balance security-scoped access. Require
the latest unreversed export event for the item. Verify URL, regular-file type,
and SHA-256 hash. Move the export to a unique same-directory staging URL,
commit removal from `exportedItemIDs`, link both events, and append an Undo
event. Delete the staging file after commit; if commit fails, move it back to
the recorded destination and leave repository state unchanged.

- [ ] **Step 7: Run Core regression tests and commit**

```bash
swift test --filter HistoryRepositoryTests
swift test --filter ShelfRepositoryTests
git add Sources/BarrelCore/Storage/ShelfRepository.swift \
  Tests/BarrelCoreTests/HistoryRepositoryTests.swift \
  Tests/BarrelCoreTests/ShelfRepositoryTests.swift
git commit -m "feat: export and undo shelf files"
```

Expected: export, Undo, legacy repository, deduplication, and cleanup tests
pass.

### Task 4: AppKit file-promise drag bridge

**Files:**

- Create: `Sources/BarrelMac/Support/FilePromiseDragSource.swift`
- Modify: `Sources/BarrelMac/Services/ShelfStore.swift`
- Modify: `Sources/BarrelMac/Views/ContentView.swift`
- Modify: `Sources/BarrelMac/Views/SidebarView.swift`
- Test: `Tests/BarrelMacTests/FilePromiseDragSourceTests.swift`

**Interfaces:**

- Consumes: `ShelfRepository.export(itemID:to:)`.
- Produces: `ShelfFilePromiseExporting.export(itemID:to:)`, a whole-tile
  `FilePromiseDragSource`, and store refresh after completion.

- [ ] **Step 1: Write failing promise-delegate tests**

Use a fake exporter and call the delegate directly. Assert the promised
filename, destination-directory forwarding, completion after export, error
forwarding, one callback, and delegate lifetime. Assert no repository call is
made merely by constructing or cancelling a drag session.

- [ ] **Step 2: Verify the delegate tests fail**

```bash
swift test --filter FilePromiseDragSourceTests
```

Expected: failure because the bridge and delegate do not exist.

- [ ] **Step 3: Implement the bridge**

Define:

```swift
@MainActor protocol ShelfFilePromiseExporting: AnyObject {
    func export(itemID: UUID, to directoryURL: URL) async throws -> HistoryEvent
}
```

Back `FilePromiseDragSource` with an AppKit view and
`NSFilePromiseProviderDelegate`. Start the session from the whole tile,
advertise copy outside the app, retain the delegate through completion, and
call the promise completion handler only after the Core export transaction.
Continue using the current `NSItemProvider` path for text and link items.

- [ ] **Step 4: Integrate the store and both item surfaces**

Add a main-actor store export method that calls the repository off the UI
critical path, refreshes only after success, and maps errors to the existing
alert. Replace file/image `.onDrag` in both item views with the bridge while
preserving tap, context-menu, selection, and non-file drag behavior.

- [ ] **Step 5: Run Mac tests and commit**

```bash
swift test --filter FilePromiseDragSourceTests
swift test --filter ShelfPanelControllerTests
git add Sources/BarrelMac/Support/FilePromiseDragSource.swift \
  Sources/BarrelMac/Services/ShelfStore.swift \
  Sources/BarrelMac/Views/ContentView.swift \
  Sources/BarrelMac/Views/SidebarView.swift \
  Tests/BarrelMacTests/FilePromiseDragSourceTests.swift
git commit -m "feat: export files with Finder promises"
```

### Task 5: History and Undo interface

**Files:**

- Modify: `Sources/BarrelMac/Services/ShelfStore.swift`
- Modify: `Sources/BarrelMac/Views/ContentView.swift`
- Modify: `Sources/BarrelMac/Views/SidebarView.swift`
- Create: `Tests/BarrelMacTests/ShelfStoreHistoryTests.swift`

**Interfaces:**

- Consumes: `historySnapshot()`, `temporarySnapshot()`, and
  `undo(historyEventID:)`.
- Produces: `ShelfViewMode`, published `historyEvents`, `openHistory()`, and
  `undo(_:)` for both views.

- [ ] **Step 1: Write failing store tests**

Test launch refresh, newest-first events, live count excluding exported items,
24-hour pruning, successful Undo refresh, and each typed conflict routed to a
specific user-facing message without state mutation.

- [ ] **Step 2: Verify store tests fail**

```bash
swift test --filter ShelfStoreHistoryTests
```

Expected: failure because history store state and actions do not exist.

- [ ] **Step 3: Implement store view state**

Add:

```swift
enum ShelfViewMode: Hashable {
    case bucket
    case history
    case trash
}

@Published private(set) var historyEvents: [HistoryEvent] = []
```

Refresh temporary items and history from one repository load. Exclude exported
items from live counts, Spotlight indexing, and normal filters. Implement
`undo(_:)` with success refresh and precise error messages.

- [ ] **Step 4: Add the History UI**

Add **History** alongside the existing bucket/Trash controls in both window
surfaces. Render newest-first event rows with filename, relative time,
`sourceName → destinationName`, and full destination path help text. Show
**Undo** only for eligible export events. Reverse events are informational.
Use this empty text: “Files moved to Finder appear here for 24 hours.”

- [ ] **Step 5: Run UI-facing tests and commit**

```bash
swift test --filter ShelfStoreHistoryTests
swift test --filter BarrelMacTests
git add Sources/BarrelMac/Services/ShelfStore.swift \
  Sources/BarrelMac/Views/ContentView.swift \
  Sources/BarrelMac/Views/SidebarView.swift \
  Tests/BarrelMacTests/ShelfStoreHistoryTests.swift
git commit -m "feat: add export history and undo UI"
```

Expected: all Mac tests pass and normal items remain selectable and draggable.

### Task 6: Full verification and manual Finder check

**Files:**

- Modify only files required to correct failures introduced by Tasks 1-5.

**Interfaces:**

- Consumes: the completed feature.
- Produces: current automated, bundle-launch, and manual evidence.

- [ ] **Step 1: Run the complete automated suite**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: zero failures and zero unexpected warnings.

- [ ] **Step 2: Build and launch the app bundle**

```bash
make verify
```

Expected: successful bundle build and launch.

- [ ] **Step 3: Run the Finder matrix**

Verify: dwell below three seconds cancels; three seconds reveals; early exit
does not hide before the minimum; drag lock wins; Finder export removes the
temporary item; collision adds a numeric suffix; History records the resolved
folder/path; cancelled drag creates no event; Undo removes an unchanged export
and restores the item; changed, missing, and moved exports remain untouched and
show specific conflicts; restart preserves unexpired history.

- [ ] **Step 4: Review the final diff against the specification**

```bash
git status --short
git diff --check HEAD~5
git diff --stat HEAD~5
```

Expected: only scoped source, test, and planning files changed; no whitespace
errors.

- [ ] **Step 5: Commit any verification-only correction**

If Step 1-4 required a scoped correction, rerun its focused test and the full
suite, then commit only that correction:

```bash
git add -p
git commit -m "fix: complete edge shelf history verification"
```

If no correction was required, do not create an empty commit.
