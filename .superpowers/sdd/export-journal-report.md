# Export Journal Report

## Outcome

Implemented a two-phase export journal that never rolls back a published user path.

- Copies and SHA-256 verifies into a mode-0700 `.barrel-export-staging` directory on the destination filesystem.
- Atomically persists `pendingExports` in the migration-safe local manifest.
- Publishes the exact promised name with macOS `renameatx_np(..., RENAME_EXCL)`.
- Finalizes exported IDs, retained local snapshot, and one history event while removing the pending record.
- Returns typed `RepositoryError.exportPendingRecovery` if publication succeeded but final manifest persistence did not.
- Recovery resumes unpublished staging, finalizes only an inode/device/hash-identical published file, and otherwise preserves the public path while cleaning only private staging and cancelling the journal record.
- Local undo overlays are excluded from mutation selection.

## Crash and race coverage

Deterministic fault injection covers:

- after private staging (no public file or pending record),
- after pending-record commit (restart publishes and finalizes),
- after publish (restart finalizes),
- immediately before final commit (restart finalizes),
- final manifest writer failure after publish,
- exact-name collision,
- another process replacing the published path, including same-content identity substitution,
- exactly-once history/event recovery.

## Verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — 161 tests, 0 failures.
- `make verify` — built and verified `dist/BarrelMac.app` successfully.
- `git diff --check` — clean.
- Source invariant scan found no export rollback removal/move of the published destination; the remaining destination move is the explicit user-requested Undo implementation.

## Notes

The hidden private staging directory is intentionally created on the destination filesystem so the no-replace publication is a single atomic rename even for external volumes. Empty staging directories may remain; recovery deletes only journal-owned staged files and never deletes or moves the public destination.
