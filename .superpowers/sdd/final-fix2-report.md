# Final re-review fix report

## Delivered

- `ShelfStore.refresh()` now builds the bucket from `temporarySnapshot()` values,
  then appends non-colliding canonical Trash items. A local Undo overlay therefore
  retains its live metadata and managed URL even when the canonical record is a
  remote tombstone.
- The store tracks overlays that collide with canonical tombstones and prevents
  normal UI mutations (stack, split, rename, pin, expiration, trash, restore,
  permanent delete, and export) from changing or resurrecting canonical sync
  state. Read-only file actions remain usable.
- Cleanup now projects quota pressure from total physical storage usage while
  keeping active export IDs outside the eligible eviction set. Protected export
  bytes can therefore drive eviction of eligible clipboard content without
  sacrificing Undo recovery.

## TDD evidence

Red:

- Focused overlay and mixed-quota regressions: 2 tests executed with 5 assertion
  failures. The store exposed the canonical tombstone with no managed URL, and
  cleanup left the eligible clipboard item live.

Green:

- The same focused command: 2 tests, 0 failures.
- Final overlay test after strengthening its usable-tile assertions: 1 test,
  0 failures.

## Final verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
  - 151 tests, 0 failures, exit 0.
- `make verify`
  - Exit 0; verified `dist/BarrelMac.app` and launched PID 2803.
- `git diff --check`
  - Exit 0.

## Concerns

- Exporting a local-only overlay is intentionally rejected as `itemNotFound` so
  a drag cannot target and mutate the canonical tombstone. Opening, revealing,
  preview/provider access, and the managed file remain available.
