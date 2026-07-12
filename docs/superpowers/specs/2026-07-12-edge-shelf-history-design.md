# Edge shelf timing and file history design

## Goal

Make the edge shelf deliberate and stable, and turn it into a temporary file
bucket with a persistent, reversible 24-hour export history.

## Edge shelf interaction

The activation area remains the full-height, three-pixel strip at the extreme
left edge of each display.

Entering the strip starts a three-second dwell period. The pointer must remain
inside the strip continuously for the full period. Leaving the strip cancels
the pending reveal.

After the shelf appears, it remains visible for at least three seconds. Pointer
exit during that interval records the intent to hide but does not close the
shelf early. At the end of the interval, the shelf hides if the pointer is
still outside and no drag lock is active. If the pointer is inside, the shelf
stays visible until a later exit.

Dragging over or from the shelf locks it open until the drag ends. Existing
cross-display behavior remains unchanged.

The state machine owns the interaction rules. The controller supplies an
injectable clock and scheduler, with production durations of three seconds.
Tests use a deterministic scheduler and do not wait for wall-clock timers.

## Temporary bucket lifecycle

Every imported file starts in the temporary bucket. Barrel continues to keep a
private managed copy; importing does not remove or modify the original file.

The whole item tile remains the drag target. Barrel uses an AppKit file-promise
drag source because SwiftUI on macOS 14 does not report a completed external
drop or its destination directory.

For a successful drop into Finder or another filesystem folder, Barrel:

1. Writes a copy from managed storage into the destination folder.
2. Chooses a nonconflicting filename without replacing existing content. It
   appends a numeric suffix before the extension when the requested name is
   already present.
3. Verifies that the write completed.
4. Removes the item from the temporary bucket.
5. Adds an export event such as `Barrel → Desktop` to History.

A cancelled or failed drag leaves the temporary item unchanged and creates no
history event. Drops into applications that do not provide a filesystem
destination remain outside the history workflow.

## History model and retention

History is a separate persistent event log, not Trash and not a second copy of
the shelf item. Each event records:

- A stable event identifier and item identifier.
- The event kind: export or undo.
- The source and destination display names.
- The resolved destination URL or security-scoped bookmark.
- The final exported filename, content hash, and event timestamp.
- The identifier of the reversed event for an undo event.

The shelf item keeps its managed relative path and content metadata. An export
marks the item as absent from the temporary bucket while retaining the managed
copy for reuse and Undo.

History shows events from the preceding 24 hours, newest first. Expiration runs
at launch, when History opens, and after a new event. Expired events are
removed. Barrel deletes a managed file only when no temporary item, history
event, or deduplicated item references it.

Existing manifests decode without history fields, so upgrades preserve current
items.

## Undo behavior

**Undo** is available only on the latest unreversed export event while that
event remains within the 24-hour retention window.

Before Undo changes the filesystem, Barrel resolves destination access and
checks that the exported path is a regular file whose content hash matches the
recorded export hash.

If verification succeeds, Barrel:

1. Deletes only the verified exported copy.
2. Restores the item to the temporary bucket.
3. Appends a reverse event such as `Desktop → Barrel`.
4. Marks the original export event as reversed.

Undo never modifies the file that the user originally imported. The reverse
event is informational and remains in History until its own 24-hour expiration.

If the exported file is missing, changed, inaccessible, or no longer a regular
file, Undo makes no filesystem or shelf-state change. The UI reports the
specific conflict and retains the export event so the user can inspect it.

## Interface

The current temporary list remains the primary shelf view. A new **History**
view lists recent movement events with time, filename, source, and destination.
Eligible export events include an **Undo** action. Reverse events do not include
another Undo action.

History uses folder display names for concise labels and exposes the full path
as secondary text or a tooltip. Empty History explains that successful Finder
exports remain visible for 24 hours.

## Safety and permissions

Barrel never overwrites a destination file during export or Undo. It never
deletes an exported file unless the path and content hash both match the
recorded event.

The current non-sandboxed build can persist destination URLs. The persistence
format also supports security-scoped bookmark data so a future sandboxed build
can retain authorized access without changing the history schema. Access to a
resolved security-scoped URL is balanced for every operation.

## Verification

Automated tests cover:

- Three-second dwell, dwell cancellation, minimum visible duration, pending
  hide behavior, and drag locking.
- Accepted, cancelled, and failed file-promise exports.
- Collision-safe destination naming and resolved destination recording.
- Temporary-to-history transitions and persistence across restarts.
- Newest-first filtering and 24-hour expiration.
- Managed-file retention for deduplicated shelf items.
- Successful Undo, reverse-event creation, and restoration to the temporary
  bucket.
- Missing, changed, inaccessible, and nonregular destination files.
- Migration from manifests without history data.

A manual Finder check confirms the cross-process drag, destination label,
minimum shelf visibility, and Undo flow because unit tests cannot fully emulate
Finder's drag negotiation.

## Non-goals

- Barrel does not remove the original imported file.
- Undo does not move an export back to the original import folder.
- History does not retain events longer than 24 hours.
- The feature does not add a configurable timing or retention preference.
- Non-filesystem application drops do not create movement history.
