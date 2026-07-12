# Task 4 report

## Status

Implemented the protocol-backed Finder selection reader with AppleScript/Apple Events.

## Behavior

- Reads Finder selection only when Finder is the frontmost application.
- Executes AppleScript on a detached task so Apple Events do not block the main actor.
- Parses Apple-event descriptors through a pure parser that accepts only ordered lists of file URL or alias descriptors.
- Preserves file/folder URL order and distinguishes selection, empty selection, unavailable/malformed responses, and Automation permission denial (`-1743`).
- Uses neither Accessibility APIs nor synthetic keyboard input.

## TDD evidence

- Red: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FinderSelectionReaderTests` failed because the reader, state, result, and parser symbols did not exist.
- The first implementation run caught an overly permissive parser: `fileURLValue` coerced a string descriptor into a URL, causing the malformed-list test to fail.
- Green: the parser was constrained to file URL and alias descriptor types; all 6 focused tests passed.

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
