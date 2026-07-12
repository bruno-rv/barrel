# Quick Send design

## Goal

Add a keyboard-first Quick Send panel that imports the current Finder
selection, searches temporary items and recent History, sends files to recent
destinations, and undoes the latest eligible movement without opening the
edge shelf.

## Shortcuts and panel behavior

Barrel keeps the existing configurable shelf shortcut unchanged. Settings add
a second independently configurable shortcut for Quick Send.

The Quick Send shortcut activates Barrel and opens a compact panel centered on
the active screen. The panel accepts keyboard focus immediately and focuses its
search field. It uses a dedicated activating `NSPanel`; it does not reuse the
edge shelf's nonactivating panel.

Opening Quick Send again brings the existing panel forward instead of creating
another instance. **Escape** closes the panel without changing data. Clicking
outside may dismiss the panel when no operation is running.

Keyboard behavior is consistent throughout the panel:

- **Up Arrow** and **Down Arrow** change the selected result.
- **Return** performs the selected result's primary action.
- **Command-Return** opens the selected result's secondary actions.
- **Escape** closes a secondary action list first, then closes the panel.

## Finder selection

When Quick Send opens, Barrel requests the current Finder selection through a
protocol-backed Apple Events reader. The generated app bundle includes the
required macOS Automation usage description.

When Finder has selected files or folders, the first result is **Hold N Finder
Items**. Activating it imports the selected URLs through the existing
repository import path. Barrel never removes or modifies the Finder originals.

If Finder is unavailable, has no selection, or is not the relevant source,
Quick Send omits the import result. If Automation permission is denied, Quick
Send remains usable and shows a concise explanation with an action that opens
the appropriate System Settings privacy page.

Barrel does not request Accessibility permission or synthesize copy commands.

## Search and result types

Quick Send uses one search field and one ranked result list. An empty query
shows actions and recent content. A nonempty query searches case-insensitively
across filenames, item titles, tags, movement source and destination names,
and destination folder names.

Results are grouped and ranked in this order:

1. **Hold Finder Selection**, when available.
2. **Undo Latest Move**, when an eligible event exists.
3. Temporary shelf items.
4. History events from the existing 24-hour window.
5. Recent destination folders.

Exact prefix matches rank before substring matches inside each group. Ties use
the item's existing recency order. Stable identifiers preserve keyboard
selection while asynchronous Finder and store results refresh.

Temporary text, link, and stack items remain searchable, but Quick Send exposes
only actions that their existing data supports. Direct filesystem sending is
available only for file and image items with managed files.

## Actions

### Finder selection

The primary action imports all readable selected URLs. A partial import keeps
successful items and reports failures using the existing import result model.

### Temporary items

The primary action for a file or image opens its recent-destination list. The
user chooses a folder and Quick Send calls the existing crash-safe export
transaction. Exact-name collisions fail without overwrite or filename
suffixing.

Secondary actions reuse valid existing item behavior, including **Open** and
**Reveal in Finder**. Local tombstone overlays retain their existing restricted
mutation behavior while remaining re-exportable.

### History

The primary action for the latest eligible export is **Undo**. Other History
events expose **Open** and **Reveal in Finder** when the recorded destination
still exists. Reverse events are informational and do not offer another Undo.

**Undo Latest Move** executes the same validated repository operation as the
History interface; Quick Send does not duplicate Undo rules.

### Recent destinations

Quick Send derives destination folders from History, standardizes their URLs,
deduplicates them, and orders them by most recent use. Only events within the
24-hour History window contribute destinations.

Barrel persists a destination-directory bookmark with each export event. The
directory bookmark, rather than a file bookmark, authorizes later sibling-file
creation under a future sandboxed build. Existing events without a directory
bookmark fall back to their destination URL in the current unsandboxed build.

## State and architecture

`QuickSendPanelController` owns panel lifecycle and focus. `QuickSendModel`
owns query, selection, Finder permission state, result ranking, and action
routing. A `FinderSelectionReading` protocol isolates Apple Events from the
model and tests.

The model consumes the shared `ShelfStore`. It does not own repository state or
duplicate import, export, History, retention, Undo, pending-export recovery, or
sync logic. Store refreshes repopulate the model after successful actions.

The global hot-key controller registers and dispatches shelf and Quick Send
shortcuts independently. Invalid or conflicting shortcut choices display a
Settings error and do not silently replace the other registration.

## Success and error behavior

A successful one-shot import, export, or Undo refreshes the shared store and
closes Quick Send. Opening, revealing, or entering a secondary destination list
keeps it open as appropriate.

Failed actions keep the panel open, preserve the current query and selection,
and display a concise inline error. Pending export recovery refreshes store
state immediately and blocks duplicate retries, matching the main shelf.

Finder permission failure disables only Finder selection import. Search,
recent destinations, export, History, and Undo continue to work.

## Privacy and documentation

Update the privacy documentation to explain that Quick Send asks Finder for
selected file URLs only when the panel opens. Barrel does not inspect Finder
windows continuously and does not transmit selection data.

Update Settings and the README to document the second shortcut, Automation
permission, keyboard controls, and collision behavior.

## Verification

Automated tests cover:

- Independent registration, changes, conflicts, and dispatch for both global
  shortcuts.
- Finder selected files, empty selection, unavailable Finder, denied
  permission, and malformed Apple Events responses.
- Result grouping, prefix ranking, substring ranking, stable selection, and
  empty-query behavior.
- Temporary-item, History, Undo-latest, and recent-destination eligibility.
- Destination deduplication, 24-hour filtering, directory bookmarks, restart
  persistence, and legacy event decoding.
- Successful and failed import, export, Undo, and pending-recovery refresh.
- Panel focus, keyboard navigation, secondary actions, Escape dismissal, and
  single-instance behavior.
- Existing edge shelf, History, sync, overlay, export-journal, and Undo
  regressions.

Final verification runs the full Swift test suite and `make verify`. A manual
macOS check confirms both configurable shortcuts, Finder Automation consent,
selection import, keyboard focus, recent-destination export, Undo, and denial
behavior because Apple Events consent and cross-process selection cannot be
fully validated in unit tests.

## Non-goals

- Quick Send does not replace the edge shelf or its shortcut.
- Quick Send does not add a Finder extension or Finder Service.
- Quick Send does not request Accessibility permission.
- Quick Send does not retain History or recent destinations beyond 24 hours.
- Quick Send does not add configurable ranking or retention preferences.
- Quick Send does not export text, links, or stacks as filesystem files.
