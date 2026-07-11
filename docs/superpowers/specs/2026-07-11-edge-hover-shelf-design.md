# Edge-hover shelf design

## Objective

Make Barrel available from the left edge of every macOS display and Space,
including Spaces occupied by full-screen applications. The shelf must stay out
of the way until the pointer reaches the screen edge, then provide a reliable
surface for dragging documents into and out of Barrel.

## Product behavior

Barrel uses one shelf panel. The panel follows the pointer rather than staying
on the primary display. Reaching the configured edge of any display reveals the
panel on that display and in the current Space.

The default expanded size is 280 by 480 points. The hidden panel sits fully
off-screen, with no persistent tab or sliver. A two-to-three-point activation
zone at the display edge starts a reveal after approximately 100 milliseconds.
Leaving the panel starts a hide after approximately 250 milliseconds. Returning
before the delay expires cancels the hide.

The panel stays expanded while the pointer is over it, while it accepts an
external drag, and throughout a drag that starts from a shelf item. The panel
must not hide between picking up a document and dropping it into another app.

The shelf defaults to the left edge with auto-hide enabled. Settings continue
to offer the right edge and a persistent shelf. A one-time preference migration
sets existing installations to the new left-edge, auto-hide defaults. After the
migration, Barrel must preserve later user changes.

## Window architecture

Replace the normal SwiftUI shelf `WindowGroup` with one AppKit-managed
`NSPanel`. Keep Settings and the menu-bar extra as SwiftUI scenes.

`ShelfPanelController` owns the shelf panel and hosts the existing
`ContentView` in an `NSHostingView`. The panel uses a borderless,
non-activating style so revealing it does not make Barrel the active app or
take keyboard focus from the user's current app. Interactive controls may
request focus only when the user explicitly clicks them.

Configure the panel to:

- Join every Space.
- Act as a full-screen auxiliary window.
- Stay stationary during Space transitions.
- Stay above ordinary and full-screen application windows.
- Stay out of the normal window cycle and avoid a Dock presence solely for the
  shelf.
- Remain visible when Barrel is not the active application.

The app delegate owns the shared `ShelfStore` and panel controller. Menu-bar,
global-shortcut, Spotlight, and App Intent requests call the panel controller
instead of searching `NSApp.windows` for a normal shelf window.

## Edge interaction controller

Keep edge behavior separate from panel construction. An event-driven
`EdgeShelfController` receives pointer, drag, display, Space, settings, and
explicit-show events and produces panel visibility and placement decisions.

The controller tracks these states:

- `hidden`: no reveal or hide operation is pending.
- `revealPending`: the pointer is in the activation zone.
- `shown`: the pointer may interact with the shelf.
- `hidePending`: the pointer left, but the grace period has not elapsed.
- `dragLocked`: a drag is active, so automatic hiding is suspended.

Local and global event monitors observe mouse movement, mouse dragging, and
mouse-up events. Dispatch work items or cancellable tasks implement the reveal
and hide delays. Do not add a repeating polling timer.

When the pointer moves to another display, the controller cancels obsolete
animations, computes a frame for the new display, moves the same panel, and
orders it forward. Screen-parameter and active-Space notifications recompute
the panel frame and ordering even when the pointer is stationary during the
transition.

## Placement

Use the display containing `NSEvent.mouseLocation`. If no display contains the
point, use the panel's current display, then the main display.

Center the shown panel vertically within the display's usable frame. Keep a
small inset from the selected horizontal edge while shown. Place the complete
panel outside the display frame while hidden. Recompute placement for each
display so different resolutions, menu-bar locations, Dock positions, and
scaling factors do not reuse stale coordinates.

Explicit reveal commands show the panel on the display containing the pointer.
This includes the global shortcut, menu-bar **Show Shelf** command, App Intent,
and Spotlight continuation.

## Drag-and-drop behavior

The existing SwiftUI drop handling and item providers remain responsible for
importing and exporting shelf content. The new window controller only keeps the
drop surface reachable.

Dragging at the screen edge must trigger the same reveal path as ordinary
hover. A mouse-drag event locks the shelf open. Mouse-up ends the drag lock and
allows the normal hide delay to begin after the pointer leaves. SwiftUI drop
target state also locks the panel while an external item is over the shelf.

The panel must not activate Barrel during an external drag. Dragging a shelf
item into another app must leave that app eligible to become the drop target.

## Focus and activation

Hover reveal, drag reveal, and explicit non-interactive reveal must not activate
Barrel. The user keeps keyboard focus in the current app. Clicking a shelf text
field, menu, or other control may make the panel key only for that interaction.

Settings remains a normal activating window. Opening Settings must not change
the shelf's Space membership or edge state.

## Preference migration

Add a versioned migration marker for shelf-window behavior. On the first launch
of this version:

1. Set the shelf edge to left.
2. Enable auto-hide.
3. Record the migration version.

Later launches do not overwrite either preference. New installations use the
same defaults without requiring a separate migration path.

## Error handling and recovery

If the active display disappears, cancel pending movement and reposition the
panel on the main display. If a Space or display transition interrupts an
animation, apply the newest target frame without completing the obsolete
animation.

Installing an event monitor more than once must be a no-op. Stopping the
controller removes every installed monitor and observer. Panel teardown must
cancel pending reveal and hide work.

The shelf remains available through the global shortcut and menu-bar command
if edge monitoring cannot observe an event. These commands use the same panel
placement logic rather than a separate fallback window.

## Testing

Keep state and geometry calculations deterministic and test them without
requiring real pointer movement. Add automated coverage for:

- Hidden, reveal-pending, shown, hide-pending, and drag-locked transitions.
- Reveal and hide cancellation during rapid edge movement.
- Drag-in and drag-out sessions that keep the shelf visible until mouse-up.
- Selecting the display under the pointer and moving between displays.
- Frame calculations for left and right edges and differently sized displays.
- Falling back safely when a display disappears.
- Panel style, level, Space behavior, and non-activating configuration.
- One-time preference migration that preserves later user choices.
- Explicit reveal commands targeting the pointer's display.

Run the existing repository, retention, and CloudKit suites unchanged.

## Acceptance criteria

Completion requires:

- The shelf reveals from the selected edge in ordinary and full-screen Spaces.
- The shelf follows the pointer across multiple displays.
- Hover reveal does not activate Barrel or steal focus.
- The expanded panel measures 280 by 480 points by default.
- The hidden shelf leaves no visible tab.
- Users can drag documents into the shelf and from the shelf into another app
  without the panel hiding during the drag.
- The global shortcut, menu-bar command, App Intent, and Spotlight result reveal
  the custom panel on the pointer's display.
- Existing users receive the left-edge, auto-hide defaults once, while later
  settings changes persist.
- `swift test`, the release build, and bundle verification pass.
- Manual acceptance covers two displays, an ordinary Space, and a full-screen
  application.

## Non-goals

This change does not alter repository storage, retention, CloudKit sync,
Spotlight indexing, or shelf item formats. It does not create one shelf per
display, add resize controls, or redesign item tiles beyond fitting the approved
compact panel size.
