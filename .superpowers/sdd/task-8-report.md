# Task 8 report

Status: `DONE_WITH_CONCERNS`

## Changes

- Added the exact `NSAppleEventsUsageDescription` value to the generated app
  bundle plist.
- Documented the independent Shelf and Quick Send shortcuts, Finder Automation
  permission timing, keyboard controls, 24-hour recent destinations, exact-name
  collision behavior, and local-only Finder selection handling.
- Made no source or test corrections because verification found no regression.

## Verification

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` exited
with status 0:

- XCTest: 194 tests executed with 0 failures and 0 unexpected failures.
- Swift Testing: 40 tests in 3 suites passed.
- The build and test output contained no warnings.

`make verify` exited with status 0 and reported:

```text
verified /Users/bruno/Dev/barrel/dist/BarrelMac.app with PID 54730
```

`/usr/libexec/PlistBuddy -c 'Print :NSAppleEventsUsageDescription'
dist/BarrelMac.app/Contents/Info.plist` exited with status 0 and printed:

```text
Barrel uses Finder Automation only when Quick Send opens to read the files you currently selected.
```

`/usr/bin/plutil -lint dist/BarrelMac.app/Contents/Info.plist` exited with
status 0 and reported `OK`. `git diff --check` also exited with status 0.

## Remaining controller evidence

The GUI manual macOS matrix was not attempted, as directed. Controller evidence
remains for both shortcuts, initial focus, Finder consent and denial, empty and
mixed selection, partial folder failure, prefix ranking, recent-destination
export, collision presentation, Undo Latest, panel reuse, Escape behavior, and
edge-shelf activation regression coverage.
