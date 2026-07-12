# Task 8 report

Status: `DONE_WITH_CONCERNS`

## Changes

- Added the exact `NSAppleEventsUsageDescription` value to the generated app
  bundle plist.
- Documented the independent Shelf and Quick Send shortcuts, Finder Automation
  permission timing, keyboard controls, 24-hour recent destinations, exact-name
  collision behavior, and local-only Finder selection handling.
- Corrected Quick Send query handling so typing filters the Finder, shelf,
  History, and destination snapshots captured by the last full refresh without
  reading Finder or source providers again. Full controller and post-action
  refreshes retain the captured Finder-frontmost context and generation guard.
- Added a regression proving matching and nonmatching queries, plus clearing the
  query, preserve the Finder semantic ID and URLs and the captured History and
  destination results with exactly one Finder read.
- Clarified that Quick Send asks Finder only when Finder was frontmost before
  Quick Send activated Barrel.

## Verification

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` exited
with status 0:

- XCTest: 194 tests executed with 0 failures and 0 unexpected failures.
- Swift Testing: 43 tests in 3 suites passed.
- The build and test output contained no warnings.

`make verify` exited with status 0 and reported:

```text
verified /Users/bruno/Dev/barrel/dist/BarrelMac.app with PID 90232
```

`/usr/libexec/PlistBuddy -c 'Print :NSAppleEventsUsageDescription'
dist/BarrelMac.app/Contents/Info.plist` exited with status 0 and printed:

```text
Barrel uses Finder Automation only when Quick Send opens to read the files you currently selected.
```

`/usr/bin/plutil -lint dist/BarrelMac.app/Contents/Info.plist` exited with
status 0 and reported `OK`. `git diff --check` also exited with status 0.

Focused verification also passed:

- `swift test --filter QuickSendModelTests`: 24 tests.
- `swift test --filter QuickSendActionTests`: 11 tests.
- `swift test --filter QuickSendPanelControllerTests`: 8 tests.

## Remaining concern

The GUI manual macOS matrix was not attempted. Controller evidence
remains for both shortcuts, initial focus, Finder consent and denial, empty and
mixed selection, partial folder failure, prefix ranking, recent-destination
export, collision presentation, Undo Latest, panel reuse, Escape behavior, and
edge-shelf activation regression coverage.
