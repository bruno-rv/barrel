# Barrel macOS Upgrade Design

## Objective

Turn Barrel into a macOS-only, privacy-first temporary shelf with reliable
local storage, smart retention, system-wide capture, and optional synchronization
between Macs.

## Product Scope

Barrel supports macOS 14 and later. The existing iOS source tree and iOS Xcode
project will be removed. `Sources/BarrelMac` remains the only application UI.

The release contains three product features:

1. Optional CloudKit synchronization between Macs using the same iCloud account.
2. Smart retention with pinning, expiration, deduplication, storage limits, and
   recoverable trash.
3. System-wide macOS capture and recall through a global shortcut, menu-bar
   actions, App Intents, and private Spotlight indexing.

CloudKit is compiled but disabled by default because this repository has no
Apple Developer Team, CloudKit container, or production entitlements. Local
features must work without an Apple account or network connection.

## Architecture

The Swift package is split into three targets:

- `BarrelCore`: platform-neutral models, repository, retention, deduplication,
  migration, search, sync coordination, and protocols for platform services.
- `BarrelMac`: SwiftUI and AppKit presentation, clipboard access, global hotkey,
  App Intents, Spotlight indexing, thumbnails, and the optional CloudKit adapter.
- `BarrelCoreTests`: deterministic tests using temporary directories and fake
  clocks or sync transports.

UI state remains `@MainActor`. File copies, hashing, manifest encoding, cleanup,
and sync run in actors or asynchronous tasks. Views receive prepared models and
cached thumbnails rather than performing disk work while rendering.

## Data Model

`ShelfItem` keeps its stable UUID and gains:

- `origin`: `import`, `clipboard`, `shortcut`, or `sync`.
- `expiresAt`: optional expiration date.
- `isPinned`: pinned items never expire.
- `contentHash`: SHA-256 for file and image deduplication.
- `trashedAt`: optional date for recoverable deletion.
- `revision`: monotonic local revision for synchronization.
- `modifiedByDeviceID`: deterministic tie-breaking identifier.

The decoder supplies defaults for these fields so existing manifests load
without data loss. Stack children use the same model and participate in
reference tracking, retention, and synchronization.

## Repository and Storage

`ShelfRepository` is an actor and the only component allowed to mutate the
manifest or managed files. It owns these flows:

1. Stage an import in a temporary directory.
2. Hash files off the main actor.
3. Reuse an existing managed file when its hash matches, otherwise move the
   staged file into managed storage.
4. Atomically write the compact manifest.
5. Roll back staged or newly created files if the metadata commit fails.

Batch imports report success or failure per item. A failure never discards
successfully committed items. Startup maintenance scans managed files against
all top-level and nested item references and removes orphans.

Deletion first sets `trashedAt`. Restoring clears it. Permanent cleanup removes
trash older than seven days and deletes a managed file only when no live or
trashed item references it.

## Retention and Privacy

Manually imported and shortcut-created items do not expire by default.
Automatic clipboard capture is off by default. When enabled, clipboard items
expire after 24 hours unless pinned or assigned a different lifetime.

Users can choose one hour, one day, one week, or no expiration per item. Settings
provide a storage quota, defaulting to 1 GB. Cleanup removes expired unpinned
items first, then the oldest unpinned clipboard items. Deliberate imports are
never removed solely to satisfy the quota; Barrel instead reports that manual
cleanup is required.

Clipboard polling exists only while capture is enabled. Disabling capture
cancels the polling task immediately. Settings explain that captured clipboard
content is copied into Barrel storage.

## Capture and Recall

The default global shortcut is Control-Option-Space and can be disabled or
changed in settings. It reveals the floating shelf without requiring the app to
be active. The existing menu-bar extra retains import and paste actions.

App Intents expose these operations:

- Hold files in Barrel.
- Hold text in Barrel.
- Hold a link in Barrel.
- Show the Barrel shelf.
- Clear expired items.

Core Spotlight indexes item identifiers, titles, kinds, text snippets, and
dates. It does not index managed file contents. Selecting a result opens Barrel
and selects the matching item.

## Multi-Mac Synchronization

`SyncCoordinator` is independent of CloudKit and operates on versioned records.
The CloudKit adapter is optional and guarded by capability checks. When no
container is available, settings show synchronization as unavailable without
affecting local storage.

Metadata and deletion tombstones synchronize independently from file assets.
Local mutations never wait for the network. Conflicts use the latest
`updatedAt`; exact timestamp ties use `modifiedByDeviceID`. Failed transfers
remain pending and retry without reverting local changes.

The default placeholder container identifier is `iCloud.dev.bruno.barrel`.
Enabling runtime synchronization later requires a real Developer Team,
provisioned container, and matching entitlements.

## Performance Changes

- Replace synchronous main-actor imports and manifest writes with repository
  actor operations.
- Bound concurrent imports to four items.
- Downsample image thumbnails and cache them by item ID plus file modification
  date.
- Derive visible items once when items, filter, or search text changes.
- Replace the 80 ms edge timer with local and global mouse event monitoring.
- Stop clipboard polling whenever capture is disabled.
- Encode compact JSON and retain atomic writes.

## Error Handling

Storage errors include the affected item and operation. Batch operations return
partial results. Recoverable failures appear in the UI without discarding
successful work. Sync errors are retryable and never block local operations.
Corrupt manifests are preserved with a timestamped backup before Barrel starts
with an empty in-memory shelf and reports recovery instructions.

## User Interface

The existing compact floating shelf remains recognizable. Additions are limited
to:

- Pin and expiration controls in item menus and detail views.
- A Trash filter with restore and empty actions.
- Storage usage and quota controls in Settings.
- Clipboard privacy and default-expiration settings.
- Global shortcut settings.
- Cloud sync status that clearly reports when entitlements are unavailable.

## Migration and Removal

Delete `Barrel/` and `Barrel.xcodeproj/`. Remove iOS features and build
instructions from the README. Preserve the existing macOS Application Support
directory and migrate its manifest in place on first launch.

## Testing and Acceptance Criteria

Automated tests must cover:

- Legacy manifest decoding and migration.
- Atomic save rollback and orphan cleanup.
- Partial batch import success.
- File deduplication and reference-aware deletion.
- Clipboard defaults, expiration, pinning, and quota policy.
- Trash restore and permanent cleanup.
- Sync conflict resolution, tombstones, and retry state.
- Search and filter derivation.

Completion requires:

- `swift test` passes with no failures.
- `swift build` succeeds with the full Xcode toolchain.
- The staged app bundle passes the existing verification script.
- No iOS source, project, or documentation remains.
- Local operation works with CloudKit disabled and no Developer account.
- No source view performs synchronous file or full-image decoding work.

