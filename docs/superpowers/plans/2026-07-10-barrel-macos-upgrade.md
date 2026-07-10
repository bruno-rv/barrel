# Barrel macOS Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a macOS-only Barrel application with actor-isolated storage, privacy-first retention, system capture and recall, and optional multi-Mac CloudKit synchronization.

**Architecture:** A new `BarrelCore` Swift package target owns models, retention, transactional storage, search, and deterministic sync resolution. `BarrelMac` keeps AppKit and SwiftUI integrations, including clipboard capture, cached thumbnails, a global hotkey, App Intents, Spotlight, and the optional CloudKit transport. Core behavior is developed test-first in `BarrelCoreTests`.

**Tech Stack:** Swift 5 language mode, Swift Package Manager, SwiftUI, AppKit, CryptoKit, CoreSpotlight, AppIntents, CloudKit, XCTest.

## Global Constraints

- Support macOS 14 and later.
- Keep `Sources/BarrelMac` as the only application UI.
- Remove `Barrel/`, `Barrel.xcodeproj/`, and all iOS documentation.
- Add no third-party dependencies.
- Keep CloudKit disabled by default and preserve complete local functionality without entitlements.
- Preserve and migrate `~/Library/Application Support/BarrelMac/shelf.json` and its managed files.
- Ordinary imports never expire by default; automatic clipboard captures expire after 24 hours unless pinned.
- Clipboard capture defaults off; trash retention is seven days; storage quota defaults to 1 GB.
- UI mutations stay on `@MainActor`; file, hashing, manifest, cleanup, thumbnail, and sync work must not execute in SwiftUI view bodies.

---

### Task 1: Establish the macOS-only package and a failing core test

**Files:**
- Modify: `.gitignore`
- Modify: `Package.swift`
- Modify: `README.md`
- Create: `Sources/BarrelCore/BarrelCore.swift`
- Create: `Tests/BarrelCoreTests/ShelfItemTests.swift`
- Delete: `Barrel/`
- Delete: `Barrel.xcodeproj/`

**Interfaces:**
- Produces: SwiftPM targets `BarrelCore`, `BarrelMac`, and `BarrelCoreTests`.
- Produces: `BarrelCore` as an importable module with no platform UI dependencies.

- [ ] **Step 1: Commit the current untracked application as the immutable baseline**

Run:

```bash
git add .gitignore Barrel Barrel.xcodeproj Makefile Package.swift README.md Resources Sources script
git commit -m "chore: capture initial Barrel source"
```

Expected: a commit containing the pre-upgrade macOS and iOS source.

- [ ] **Step 2: Remove the iOS implementation and ignore local Codex state**

Delete `Barrel/` and `Barrel.xcodeproj/`. Add `.codex/` to `.gitignore`. Remove the iOS feature and build sections from `README.md` and describe Barrel as macOS-only.

- [ ] **Step 3: Declare the core and test targets**

Replace the package target section with:

```swift
products: [
  .library(name: "BarrelCore", targets: ["BarrelCore"]),
  .executable(name: "BarrelMac", targets: ["BarrelMac"])
],
targets: [
  .target(
    name: "BarrelCore",
    swiftSettings: [.swiftLanguageMode(.v5)]
  ),
  .executableTarget(
    name: "BarrelMac",
    dependencies: ["BarrelCore"],
    swiftSettings: [.swiftLanguageMode(.v5)]
  ),
  .testTarget(
    name: "BarrelCoreTests",
    dependencies: ["BarrelCore"],
    swiftSettings: [.swiftLanguageMode(.v5)]
  )
]
```

Create `Sources/BarrelCore/BarrelCore.swift` containing only `import Foundation` so SwiftPM can build the target.

- [ ] **Step 4: Write the first failing model test**

Create `ShelfItemTests.swift` with a legacy JSON fixture and assert that decoding supplies `.imported`, `nil` expiration, `false` pinning, `nil` trash date, revision `0`, and an empty device identifier.

```swift
import XCTest
@testable import BarrelCore

final class ShelfItemTests: XCTestCase {
  func testLegacyManifestDecodesNewFieldsWithSafeDefaults() throws {
    let data = Data(#"{"id":"60D1B05E-40A3-433D-9B25-587EB5E35C51","title":"Brief","kind":"file","createdAt":"2026-07-10T10:00:00Z","updatedAt":"2026-07-10T10:00:00Z","fileName":"Brief.pdf","relativePath":"Items/1/Brief.pdf","text":null,"children":[]}"#.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let item = try decoder.decode(ShelfItem.self, from: data)

    XCTAssertEqual(item.origin, .imported)
    XCTAssertNil(item.expiresAt)
    XCTAssertFalse(item.isPinned)
    XCTAssertNil(item.trashedAt)
    XCTAssertEqual(item.revision, 0)
    XCTAssertEqual(item.modifiedByDeviceID, "")
  }
}
```

- [ ] **Step 5: Verify RED**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

Expected: compilation fails because `ShelfItem` and `ShelfOrigin` do not exist in `BarrelCore`.

- [ ] **Step 6: Commit the macOS-only package scaffold and failing test**

```bash
git add -A
git commit -m "refactor: make Barrel a macOS-only package"
```

### Task 2: Implement shared models, retention, search, and sync resolution

**Files:**
- Create: `Sources/BarrelCore/Models/ShelfItem.swift`
- Create: `Sources/BarrelCore/Models/ShelfFilter.swift`
- Create: `Sources/BarrelCore/Retention/RetentionPolicy.swift`
- Create: `Sources/BarrelCore/Sync/SyncResolver.swift`
- Modify: `Tests/BarrelCoreTests/ShelfItemTests.swift`
- Create: `Tests/BarrelCoreTests/RetentionPolicyTests.swift`
- Create: `Tests/BarrelCoreTests/SyncResolverTests.swift`

**Interfaces:**
- Produces: `ShelfKind`, `ShelfOrigin`, `ShelfItem`, `ShelfFilter`, and `ShelfExpirationPreset` as public `Codable & Sendable` values.
- Produces: `RetentionPolicy.expirationDate(for:now:)`, `cleanupCandidates(items:now:bytesByItemID:quotaBytes:)`, and `SyncResolver.merge(local:remote:)`.

- [ ] **Step 1: Implement the minimal model required by the legacy test**

Define a custom `init(from:)` using `decodeIfPresent` for every new field. Keep existing field names and ISO-8601 dates. Make `ShelfItem` recursively searchable and add:

```swift
public var isExpired: Bool {
  !isPinned && expiresAt.map { $0 <= Date() } == true
}

public func isExpired(at date: Date) -> Bool {
  !isPinned && expiresAt.map { $0 <= date } == true
}
```

- [ ] **Step 2: Verify GREEN for legacy decoding**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ShelfItemTests`

Expected: `ShelfItemTests` passes.

- [ ] **Step 3: Write failing retention tests**

Cover these exact behaviors:

```swift
XCTAssertNil(policy.expirationDate(for: .imported, now: now))
XCTAssertEqual(policy.expirationDate(for: .clipboard, now: now), now.addingTimeInterval(86_400))
XCTAssertFalse(pinnedExpiredItem.isExpired(at: now))
XCTAssertEqual(policy.cleanupCandidates(items: items, now: now, bytesByItemID: sizes, quotaBytes: 100), [expiredID, oldestClipboardID])
```

The candidate test must prove that an imported item is never selected only to satisfy quota.

- [ ] **Step 4: Verify RED for retention**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RetentionPolicyTests`

Expected: compilation fails because `RetentionPolicy` is missing.

- [ ] **Step 5: Implement retention and deterministic filtering**

Implement one-hour, one-day, one-week, and never presets. Cleanup ordering is expired unpinned items first, followed by oldest unpinned clipboard items until projected live storage is within quota. `ShelfFilter` includes `all`, type filters, and `trash`; non-trash filters exclude `trashedAt != nil`.

- [ ] **Step 6: Write failing sync-resolution tests**

Test newer timestamp wins, an exact timestamp tie chooses lexicographically greater `modifiedByDeviceID`, and a newer tombstone wins over a live record.

- [ ] **Step 7: Verify RED for sync resolution**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SyncResolverTests`

Expected: compilation fails because `SyncResolver` is missing.

- [ ] **Step 8: Implement `SyncResolver` and verify all model tests**

Use item ID as the merge key, `updatedAt` as the primary version, and `modifiedByDeviceID` as the deterministic tie-breaker. Return results sorted newest first.

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

Expected: all model, retention, and resolver tests pass.

- [ ] **Step 9: Commit shared behavior**

```bash
git add Sources/BarrelCore Tests/BarrelCoreTests
git commit -m "feat: add shared shelf and retention models"
```

### Task 3: Build the transactional repository and migration

**Files:**
- Create: `Sources/BarrelCore/Storage/ShelfRepository.swift`
- Create: `Sources/BarrelCore/Storage/RepositoryTypes.swift`
- Create: `Tests/BarrelCoreTests/ShelfRepositoryTests.swift`

**Interfaces:**
- Produces: actor `ShelfRepository`.
- Produces: `RepositoryConfiguration(rootURL:deviceID:quotaBytes:trashRetention:now:manifestWriter:)`.
- Produces: `load()`, `snapshot()`, `importFiles(_:origin:expiresAt:)`, `addText(_:kind:origin:expiresAt:)`, `rename(id:title:)`, `stack(ids:)`, `split(id:)`, `setPinned(id:isPinned:)`, `setExpiration(id:date:)`, `trash(ids:)`, `restore(ids:)`, `emptyTrash()`, `cleanup()`, `fileURL(for:)`, and `storageUsage()`.
- Produces: `ImportOutcome` with per-URL success or failure.

- [ ] **Step 1: Write failing repository migration and rollback tests**

Use `FileManager.default.temporaryDirectory` with a unique child per test. Assert:

1. `load()` decodes a legacy manifest and preserves its item.
2. An injected manifest writer that throws leaves no staged or managed file.
3. A corrupt manifest is copied to `shelf-corrupt-<timestamp>.json` before `load()` throws `RepositoryError.corruptManifest`.

- [ ] **Step 2: Verify RED**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ShelfRepositoryTests`

Expected: compilation fails because repository types are missing.

- [ ] **Step 3: Implement repository setup, load, compact atomic save, and rollback**

Use directories `Items` and `Staging` beneath `rootURL`, manifest `shelf.json`, `JSONEncoder` with ISO-8601 dates and no pretty printing, and `Data.write(options: .atomic)` in the default manifest writer. Preserve a corrupt manifest before throwing.

- [ ] **Step 4: Verify migration and rollback tests GREEN**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ShelfRepositoryTests`

Expected: the three repository tests pass.

- [ ] **Step 5: Write failing deduplication, partial import, trash, and cleanup tests**

Add tests proving:

- Two equal files produce two items sharing one `relativePath` and one managed file.
- One unreadable URL does not discard another successfully imported URL.
- Trashing and restoring preserve the file.
- Emptying trash keeps a shared file while another live item references it.
- Startup orphan cleanup removes an unreferenced `Items/<UUID>` directory.
- Expired clipboard items move to trash while pinned items remain live.

- [ ] **Step 6: Verify RED for repository behavior**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ShelfRepositoryTests`

Expected: tests fail because import, deduplication, and mutation methods are incomplete.

- [ ] **Step 7: Implement import hashing and repository mutations**

Hash files with streaming `SHA256` from CryptoKit. Limit a batch to four concurrent staging tasks. Commit successful results independently and return failures in `ImportOutcome`. Before deleting a managed directory, recursively collect every remaining `relativePath` reference from top-level items and stack children.

- [ ] **Step 8: Verify repository tests and the full core suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

Expected: all tests pass with no warnings.

- [ ] **Step 9: Commit storage**

```bash
git add Sources/BarrelCore/Storage Tests/BarrelCoreTests/ShelfRepositoryTests.swift
git commit -m "feat: add transactional shelf repository"
```

### Task 4: Integrate `ShelfStore` with the repository and optimize derived UI state

**Files:**
- Modify: `Sources/BarrelMac/Services/ShelfStore.swift`
- Replace: `Sources/BarrelMac/Services/ImportService.swift`
- Delete: `Sources/BarrelMac/Models/ShelfItem.swift`
- Create: `Sources/BarrelMac/Models/ShelfItem+Preview.swift`
- Modify: `Sources/BarrelMac/App/BarrelMacApp.swift`
- Create: `Sources/BarrelMac/App/BarrelEnvironment.swift`
- Create: `Tests/BarrelCoreTests/SearchTests.swift`

**Interfaces:**
- Consumes: all `ShelfRepository` methods.
- Produces: `@MainActor ShelfStore` with `items`, `visibleItems`, selection, import progress, storage usage, and async actions.
- Produces: `BarrelEnvironment.shared.repository` for the app and App Intents.

- [ ] **Step 1: Write a failing deterministic search test**

Create `SearchTests` proving text matches nested stack children, trash is excluded from normal filters, and trash appears only in `.trash`.

- [ ] **Step 2: Verify RED and implement the shared filter function**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SearchTests`

Expected: fails until `ShelfFilter.filter(_:query:)` exists; implement it and rerun until green.

- [ ] **Step 3: Replace duplicate macOS models with `import BarrelCore`**

Delete `Sources/BarrelMac/Models/ShelfItem.swift`; recreate only its preview fixtures in `Sources/BarrelMac/Models/ShelfItem+Preview.swift` as a macOS-only extension. Replace `ImportService` with an `NSItemProvider` adapter that converts providers to temporary URLs, images, links, or text and calls the repository.

- [ ] **Step 4: Convert store mutations to async repository calls**

Initialize by awaiting `repository.load()`. After each repository mutation, refresh `items`, recompute `visibleItems`, update selection, storage usage, and the Spotlight index. `searchText` and `filter` recompute from the current snapshot without disk access.

- [ ] **Step 5: Make clipboard capture opt-in and cancellable**

Add `setClipboardCapture(enabled:)`. When enabled, create one task that sleeps two seconds between `NSPasteboard.changeCount` checks; when disabled, cancel and clear the task. Clipboard-created repository items use `.clipboard` and the policy-provided 24-hour expiration.

- [ ] **Step 6: Build and fix only integration compiler errors**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`

Expected: successful compile after all callers await async store actions and import `BarrelCore`.

- [ ] **Step 7: Run tests and commit store integration**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
git add Sources/BarrelMac Sources/BarrelCore Tests/BarrelCoreTests
git commit -m "refactor: move shelf state onto the core repository"
```

### Task 5: Add privacy, retention, trash, and storage UI

**Files:**
- Modify: `Sources/BarrelMac/Views/ContentView.swift`
- Modify: `Sources/BarrelMac/Views/SidebarView.swift`
- Modify: `Sources/BarrelMac/Views/DetailView.swift`
- Modify: `Sources/BarrelMac/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `ShelfStore.visibleItems`, pin, expiration, trash, restore, empty-trash, cleanup, and storage properties.
- Produces: settings keys `CaptureClipboardHistory=false`, `ClipboardLifetimeHours=24`, `StorageQuotaBytes=1073741824`, `GlobalHotKeyEnabled=true`, and `GlobalHotKeyChoice=control-option-space`.

- [ ] **Step 1: Change privacy defaults and connect settings to store behavior**

Set clipboard history to `false` in every `@AppStorage` declaration. Add an explanatory privacy footer, a 24-hour default lifetime picker, storage quota picker, live usage label, and cleanup button.

- [ ] **Step 2: Add pinning and expiration controls**

Item context menus and detail views expose Pin/Unpin and expiration presets of one hour, one day, one week, and never. Display an expiration badge only for unpinned expiring items.

- [ ] **Step 3: Add trash UI**

Add the `.trash` filter. Trash rows show Restore and Delete Permanently; the footer exposes Empty Trash while the filter is active. Existing Delete actions call soft trash rather than permanent deletion.

- [ ] **Step 4: Build and manually inspect previews**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`

Expected: build succeeds with no synchronous `NSImage(contentsOf:)` added to a view body.

- [ ] **Step 5: Commit retention UI**

```bash
git add Sources/BarrelMac/Views
git commit -m "feat: add smart retention and recoverable trash"
```

### Task 6: Cache thumbnails and replace window polling

**Files:**
- Create: `Sources/BarrelMac/Services/ThumbnailCache.swift`
- Modify: `Sources/BarrelMac/Views/ContentView.swift`
- Modify: `Sources/BarrelMac/Views/DetailView.swift`
- Modify: `Sources/BarrelMac/Support/WindowConfigurator.swift`

**Interfaces:**
- Produces: `ThumbnailCache.shared.image(for:itemID:maxPixelSize:) async -> NSImage?`.
- Produces: mouse event monitors that call the existing edge show/hide state machine without a repeating timer.

- [ ] **Step 1: Implement asynchronous downsampled thumbnail caching**

Use ImageIO `CGImageSourceCreateThumbnailAtIndex` on a detached task with `kCGImageSourceThumbnailMaxPixelSize`, `kCGImageSourceCreateThumbnailFromImageAlways`, and transform enabled. Cache by URL, modification date, and requested pixel size in `NSCache`.

- [ ] **Step 2: Replace synchronous image decoding in views**

Create a small `CachedThumbnailView` that owns `@State private var image: NSImage?` and loads with `.task(id:)`. Use it in shelf tiles and detail preview. Remove every `NSImage(contentsOf:)` from SwiftUI body code.

- [ ] **Step 3: Replace the 80 ms timer with event monitors**

Register both `NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved])` and `NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved])`. Each invokes `tick()` using `NSEvent.mouseLocation`. Remove monitors in `stop()` and retain the existing frame, hot-zone, and animation calculations.

- [ ] **Step 4: Verify source and build**

Run:

```bash
rg -n "scheduledTimer|NSImage\(contentsOf:" Sources/BarrelMac
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

Expected: `rg` finds neither pattern and the build succeeds.

- [ ] **Step 5: Commit performance changes**

```bash
git add Sources/BarrelMac
git commit -m "perf: move thumbnail and window work off render paths"
```

### Task 7: Add global capture, App Intents, and Spotlight recall

**Files:**
- Create: `Sources/BarrelMac/Services/GlobalHotKeyController.swift`
- Create: `Sources/BarrelMac/Services/SpotlightIndexer.swift`
- Create: `Sources/BarrelMac/Automation/BarrelIntents.swift`
- Modify: `Sources/BarrelMac/App/BarrelMacApp.swift`
- Modify: `Sources/BarrelMac/Views/SettingsView.swift`

**Interfaces:**
- Produces: `Notification.Name.showBarrelShelf`, `.selectShelfItem`, and `.repositoryDidChange`.
- Produces: five App Intents: `HoldFilesIntent`, `HoldTextIntent`, `HoldLinkIntent`, `ShowShelfIntent`, and `ClearExpiredIntent`.
- Produces: `SpotlightIndexer.update(items:) async` and `removeAll() async`.

- [ ] **Step 1: Implement the global hotkey controller**

Use Carbon `RegisterEventHotKey` with fixed choices represented by `GlobalHotKeyChoice`: Control-Option-Space, Control-Shift-Space, and Command-Option-B. Re-register when `GlobalHotKeyEnabled` or `GlobalHotKeyChoice` changes. The event handler posts `.showBarrelShelf`.

- [ ] **Step 2: Connect shelf activation and selection**

The app delegate observes `.showBarrelShelf`, activates `NSApp`, and brings the main shelf window forward. Handle Spotlight continuation through `application(_:continue:restorationHandler:)`, read `CSSearchableItemActivityIdentifier`, and post `.selectShelfItem` with the UUID.

- [ ] **Step 3: Implement private Spotlight indexing**

Map live items to `CSSearchableItem` using item UUID as `uniqueIdentifier`, title, kind, text snippet, added date, and `contentURL` only for Barrel deep links. Delete stale Barrel-domain items before indexing the current snapshot.

- [ ] **Step 4: Implement App Intents**

Each hold intent obtains `BarrelEnvironment.shared.repository`, performs one repository operation with origin `.shortcut`, posts `.repositoryDidChange`, and returns a success dialog. `ShowShelfIntent` posts `.showBarrelShelf`; `ClearExpiredIntent` calls repository cleanup and posts the change notification.

- [ ] **Step 5: Add hotkey settings and verify compilation**

Add an enable toggle and picker for the three choices. Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: build and tests succeed.

- [ ] **Step 6: Commit system integration**

```bash
git add Sources/BarrelMac
git commit -m "feat: add system-wide capture and recall"
```

### Task 8: Add optional CloudKit transport and sync status

**Files:**
- Create: `Sources/BarrelMac/Sync/CloudKitSyncService.swift`
- Create: `Sources/BarrelMac/Sync/SyncController.swift`
- Modify: `Sources/BarrelMac/Views/SettingsView.swift`
- Create: `Tests/BarrelCoreTests/SyncCoordinatorTests.swift`
- Modify: `Sources/BarrelCore/Sync/SyncResolver.swift`

**Interfaces:**
- Produces: `SyncRecord` containing `item: ShelfItem` and `assetURL: URL?`.
- Produces: `SyncTransport` protocol with `fetch() async throws -> [SyncRecord]` and `push(_:) async throws`.
- Produces: `SyncCoordinator.synchronize(local:transport:) async throws -> [SyncRecord]`.
- Produces: `CloudKitSyncService(containerIdentifier: "iCloud.dev.bruno.barrel")` using the private database.
- Produces: `SyncController.Status` values `disabled`, `unavailable(String)`, `syncing`, `synced(Date)`, and `failed(String)`.

- [ ] **Step 1: Write failing coordinator tests**

Use an in-memory transport to prove remote-newer records and their asset URLs are returned, local-newer records are pushed, tombstones remain in the merged result, and a thrown transport error leaves the input snapshot unchanged.

- [ ] **Step 2: Verify RED**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SyncCoordinatorTests`

Expected: compilation fails because `SyncTransport` and `SyncCoordinator` are missing.

- [ ] **Step 3: Implement and verify the platform-independent coordinator**

Fetch remote records, merge item metadata through `SyncResolver`, retain the winning record's asset URL, push records whose resolved version is local, and return the merged snapshot only after successful transport completion. Add repository methods `syncRecords()` and `applySyncRecords(_:)`; the latter copies a missing remote asset into managed storage before committing metadata.

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SyncCoordinatorTests`

Expected: all coordinator tests pass.

- [ ] **Step 4: Implement the optional CloudKit transport**

Use a custom record zone named `Barrel`, record type `ShelfItem`, UUID record names, JSON-encoded item data in `payload`, `updatedAt`, `modifiedByDeviceID`, and an optional `CKAsset` for managed files. Create the zone before the first query. Implement async continuations around `CKQueryOperation` and `CKModifyRecordsOperation` so pagination and per-record errors are handled.

- [ ] **Step 5: Gate runtime activation without entitlements**

Default `CloudSyncEnabled` to false. When enabled, call `CKContainer.accountStatus`; map `.available` to sync, all other statuses and CloudKit entitlement errors to `.unavailable` or `.failed`. Never block repository load or local mutations.

- [ ] **Step 6: Add settings status and manual sync**

Show the inactive default container identifier, status text, enable toggle, and Sync Now button. Explain that a provisioned Developer Team and matching entitlements are required.

- [ ] **Step 7: Verify and commit sync**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
git add Sources Tests
git commit -m "feat: add optional multi-Mac sync"
```

### Task 9: Documentation, bundle verification, and acceptance checks

**Files:**
- Modify: `README.md`
- Modify: `script/build_and_run.sh`
- Modify: `Makefile`
- Create: `docs/cloudkit-setup.md`
- Create: `docs/privacy.md`

**Interfaces:**
- Produces: accurate build, privacy, hotkey, retention, and optional CloudKit
  setup documentation.
- Produces: a verification mode that builds and inspects the app without
  requiring CloudKit entitlements.

- [x] **Step 1: Update user and developer documentation**

Document macOS-only support, import and capture flows, default-off clipboard
behavior, 24-hour clipboard expiry, trash retention, quota behavior, global
shortcut choices, App Intents, Spotlight, and the exact commands `make app`,
`make verify`, and `swift test`.

- [x] **Step 2: Document CloudKit activation**

`docs/cloudkit-setup.md` must list the placeholder container
`iCloud.dev.bruno.barrel`, required Developer Team, iCloud capability, CloudKit
container creation, entitlements, production schema deployment, and the
expectation that sync remains disabled without them.

- [x] **Step 3: Harden the verification script**

Keep full-Xcode `DEVELOPER_DIR` selection. In `--verify`, assert the app bundle,
executable, icon, and Info.plist exist; run the executable long enough to
confirm a live process; then terminate only the process started by the script.

- [x] **Step 4: Run fresh acceptance verification**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
./script/build_and_run.sh --verify
rg -n "iOS|iPhone|iPad|UIKit" README.md Sources Package.swift
rg -n "scheduledTimer|NSImage\(contentsOf:" Sources/BarrelMac
git status --short
```

Expected: tests and builds succeed; bundle verification succeeds; both `rg`
commands return no matches; Git status contains only intentional plan-tracking
changes.

- [x] **Step 5: Commit documentation and verification**

```bash
git add README.md Makefile script docs
git commit -m "docs: document the macOS shelf workflow"
```

- [x] **Step 6: Record final evidence**

Capture test count, build result, bundle verification result, remaining
entitlement limitation, and final `git status --short` in the implementation
handoff.
