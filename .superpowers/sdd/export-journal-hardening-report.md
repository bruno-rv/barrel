# Export journal hardening report

## Root causes

- Export staging trusted an existing `.barrel-export-staging` path. `createDirectory` neither rejected a symlink nor corrected permissive permissions on an existing directory, and the code did not explicitly verify that staging and publication used the same filesystem.
- The cleanup scope ended before staged file identity and the pending-manifest commit. An identity lookup failure could therefore leave an unjournaled private copy behind.
- A journaled pending export was not reflected in `temporarySnapshot()` or `exportableItem(id:)`. After a recoverable failure the UI could keep showing the item and accept another drag before restart recovery.
- `ShelfStore.export` refreshed only on success. Recoverable pending errors changed durable repository state without notifying observers or refreshing the visible shelf.
- One recovery error message claimed publication even for the pre-publication `afterPendingCommit` state.

## Changes

- Validate staging with `lstat`, reject symlinks and non-directories, open it with `O_NOFOLLOW`, enforce mode `0700` with `fchmod`, and compare filesystem device IDs with the destination directory before copying.
- Keep copy, hash verification, identity capture, event creation, and pending-manifest commit inside one cleanup scope. Only a successfully journaled staged file survives an error.
- Exclude pending item IDs from temporary snapshots and reject another export of a pending item.
- Refresh and notify from `ShelfStore` when `exportPendingRecovery` is caught.
- Add `ExportRecoveryPhase` with `publicationPending` and `publishedPendingFinalization`, and use phase-accurate localized messages.

The public destination remains outside all cleanup paths. Collision and recovery logic still moves/removes only the private staged path unless the exclusive publish succeeds.

## TDD evidence

Focused regressions were observed failing before production edits:

- Existing staging mode remained `0777` instead of `0700`.
- A symlinked staging path was followed, copied into its target, and published.
- An injected staged-identity failure left the private staged file behind.
- A pending item remained in `temporarySnapshot()` and a retry reached pending recovery again.
- Pre-publication recovery displayed the published-but-unfinalized message.
- `ShelfStore` left the pending item visible after a final-commit failure.

After the minimal fixes, all focused regressions passed.

## Verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`: 167 tests, 0 failures.
- Focused staging tests after the descriptor-based no-follow hardening: 2 tests, 0 failures.
- `make verify`: built and launched `dist/BarrelMac.app`; launch verification succeeded.
- `git diff --check`: clean.

The active command-line-tools selection cannot run this package's tests directly because it lacks Xcode's XCTest and preview macro plugins. Test runs therefore set `DEVELOPER_DIR` to the installed Xcode application, matching the project build script.
