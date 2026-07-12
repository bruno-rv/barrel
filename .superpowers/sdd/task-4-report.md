# Task 4 report

## Status

Implemented the protocol-backed Finder selection reader with direct Apple Events.

## Behavior

- Reads Finder selection only when Finder is the frontmost application.
- Executes the Apple Event on a detached task so Finder IPC does not block the main actor.
- Requests Finder's selection as resolved aliases, normalizes only alias/file URL reply items to file URLs, then passes only ordered file URL lists to the strict parser.
- Preserves file/folder URL order and distinguishes selection, empty selection, unavailable/malformed responses, and Automation permission denial (`-1743`).
- Uses neither Accessibility APIs nor synthetic keyboard input.

## TDD evidence

- Red: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FinderSelectionReaderTests` failed because the reader, state, result, and parser symbols did not exist.
- The first implementation run caught an overly permissive parser: `fileURLValue` coerced a string descriptor into a URL, causing the malformed-list test to fail.
- Green: the parser was constrained to file URL descriptors; all 6 original focused tests passed.

## Concerns

- Automation consent and Finder's cross-process descriptor response require a manual smoke test in the signed app bundle; unit tests use injected executors and real descriptor objects.

## 2026-07-12 hardening follow-up

- Replaced `NSAppleScript` with a background `AESendMessage` path targeting Finder's bundle identifier and requesting its `selection` property directly.
- Added an injectable executor boundary. Its production normalizer calls `AECoerceDesc(..., typeFileURL, ...)` for every returned selection item before constructing parser input; tests inject send/coercion closures and never send live events.
- Tightened the pure parser to accept only ordered `typeFileURL` list items. Alias, string, non-list, and failed-coercion responses are rejected.
- Preserved the frontmost-Finder gate and Automation denial mapping for error `-1743`.
- RED: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FinderSelectionReaderTests` failed because `FinderAppleEventExecutor` did not exist; the alias parser test also captured the required strictness change.
- GREEN (focused): the same command executed 9 tests with 0 failures.
- GREEN (full): `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` executed 192 tests with 0 failures.
- Static scope check found no `NSAppleScript`, `osascript`, Accessibility, or synthetic-input usage in the changed reader/tests.
- Remaining concern: the signed-app Automation consent and Finder reply require a manual smoke test; unit tests deliberately do not contact Finder.

## 2026-07-12 real Finder resolution follow-up

- Root cause: the direct `get data` event omitted `keyAERequestedType`, so Finder could return unresolved object specifiers that cannot be usefully coerced to file URLs in the caller process.
- The production event now sets `keyAERequestedType` to `typeAlias`, matching the requested-type behavior of `selection as alias list`; Finder performs object resolution before replying.
- Local `AECoerceDesc` is now limited to resolved `typeAlias` or `typeFileURL` reply items and always requests `typeFileURL`. Object-specifier reply items fail without attempting local coercion.
- The production-event seam records the actual event and coercion arguments. Tests assert event class/ID, direct-object specifier, requested alias type, alias reply order, file-URL coercion type/order, and object-specifier rejection.
- RED: the focused test target failed to compile because the existing executor seam could not inspect the event or coercion destination type.
- GREEN (focused): `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FinderSelectionReaderTests` executed 10 tests with 0 failures.
- GREEN (full): `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` executed 193 tests with 0 failures.
