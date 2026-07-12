# Overlay Re-export Merge-Gate Report

## Outcome

Retained local overlays created by export → remote tombstone → Undo can be dragged/exported again without resurrecting or mutating the canonical tombstone. A second Undo removes the new destination copy and restores the overlay.

## Implementation

- `ShelfRepository.export` resolves a tombstoned canonical ID to its eligible live retained snapshot only when that snapshot is neither trashed nor deleted.
- The existing exact-name collision, managed-file byte/hash verification, export history transaction, rollback, and local `exportedItemIDs` behavior remain the export path.
- The retained live snapshot, rather than the canonical tombstone, is kept as recovery metadata.
- `ShelfStore.export` permits the overlay path.
- Shelf UI and detail UI query the store's overlay/read-only state. Canonical mutation controls (selection/stack, pin, expiration, rename, trash) are hidden or disabled, while open, reveal, and whole-tile file-promise export remain available.

## TDD Evidence

The new repository regressions first failed with `RepositoryError.itemNotFound` at `ShelfRepository.swift:148`; the store integration regression first failed with the same error at `ShelfStore.swift:370`. After the minimal production changes:

- `HistoryRepositoryTests`: 24/24 passed.
- `ShelfStoreHistoryTests`: 12/12 passed.
- Coverage verifies successful re-export, exact requested filename and collision behavior, exported bytes/hash, new history event, overlay removal, full `SyncRecord` equality before/after, canonical tombstone preservation, and second Undo restoration.

The initial invocation under Command Line Tools could not import `XCTest`; all behavioral RED/GREEN and final verification used `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Final Verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — 154 tests passed, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make verify` — app built and verified at `dist/BarrelMac.app`.
- `git diff --check` — clean.

## Remaining Concern

Automated coverage exercises the repository, store, and file-promise forwarding boundaries. A real Finder drag remains a manual macOS interaction check; no automated test in this package drives Finder's cross-process drag negotiation.
