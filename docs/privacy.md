# Privacy and local data

Barrel stores shelf metadata and managed file copies in its Application
Support directory. It leaves the original files unchanged.

Barrel uses AppKit local and global mouse-event monitors transiently to reveal
the shelf at the display edge. It doesn't store pointer coordinates or request
Accessibility access.

## Clipboard capture

Clipboard history is off by default. When you enable it, Barrel checks for
supported clipboard changes while capture remains enabled. It copies captured
content into Barrel storage and sets a 24-hour expiration by default.

You can choose a different lifetime or pin an item. Disabling clipboard
history stops polling. Existing captures remain subject to their retention
settings until you delete them.

Barrel doesn't add clipboard-origin items to Core Spotlight. If you separately
enable CloudKit sync, clipboard items can synchronize through your private
CloudKit database like other shelf items.

## Local search and Spotlight

Barrel searches its local manifest by title, displayed details, text, and
nested stack items. Core Spotlight receives only live, non-clipboard items.
The Spotlight record can include the item identifier, title, kind, added date,
and a short text or detail snippet.

Barrel doesn't ask Spotlight to index the contents of managed files. Spotlight
errors appear in the app and in the system log.

## Retention and deletion

Manual imports and App Intent captures don't expire unless you assign a
lifetime. Automatic clipboard captures expire after 24 hours by default.
Pinned items don't expire.

Expired items move to Trash. You can restore them for seven days. Emptying
Trash, deleting an item permanently, or running cleanup after seven days
deletes unreferenced managed files.

Barrel retains a minimal deletion tombstone so an older synchronized record
can't restore permanently deleted content. The tombstone contains neutral
identity, version, and deletion metadata. It removes titles, text, filenames,
paths, content hashes, and nested children.

## Storage quota

The default quota is 1 GB. Cleanup selects expired, unpinned items first, then
oldest unpinned clipboard captures. It doesn't select deliberate imports only
to satisfy the quota.

Moving an item to Trash doesn't immediately remove its managed file. If disk
usage remains above the quota, empty Trash or delete items manually.

## Optional CloudKit sync

CloudKit sync is off by default. When you enable it in a correctly signed app,
Barrel sends item metadata, deletion tombstones, and managed file assets to the
private database for `iCloud.dev.bruno.barrel`.

Fetched assets move immediately into app-owned staging before Barrel merges
them into local storage. Barrel removes that staging data after the sync
finishes or fails. Disabling sync cancels pending work where the system APIs
allow cancellation.

Without the required iCloud container and CloudKit service entitlements,
Barrel reports sync as unavailable. Local shelf operations don't wait for or
depend on the network.

See [Configure optional CloudKit sync](cloudkit-setup.md) for provisioning and
manual test requirements.

## Global shortcut

The global shortcut uses the macOS Carbon hot-key service. Barrel reports a
registration error in settings if another app or the system reserves the
selected key combination. The shortcut doesn't record typed keys.
