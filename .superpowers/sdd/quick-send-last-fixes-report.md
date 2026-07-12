# Quick Send Last Fixes Report

## Root causes

- `QuickSendPanelController.show()` always ran the new-session path. Re-triggering the shortcut while the retained panel was visible recaptured Finder context, recentered the panel, and asynchronously refreshed the model, replacing session state.
- `RecentDestinationResolver.destinations(from:)` resolved bookmark URLs but validated them with `fileExists` before starting security-scoped access. Sandboxed bookmark directories can be observable only while that scope is active.

## Changes

- Visible-panel `show()` calls now only activate Barrel, bring the same panel key/front, and schedule search-field focus. Hidden-panel calls retain context capture, centering, and refresh behavior. The visible path has no busy-state guard, so an in-flight operation is preserved while activation and focus still occur.
- Bookmark candidates now start security-scoped access before directory validation and balance successful starts with a deferred stop. Invalid bookmark candidates fall back to the unchanged unscoped legacy parent path.
- Added integration coverage for repeated visible shows preserving panel identity, frame, query, results, Finder semantic identity/URLs and selection, secondary mode, busy state, and reader/context counts while repeating activation/focus. The same test proves a later hidden show refreshes again.
- Added injected-scope tests for valid and invalid bookmark candidates, plus retained async export-scope coverage with balanced resolution/export lifetimes.

## TDD evidence

Red:

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter QuickSendPanelControllerTests.repeatedShowWhileVisiblePreservesSessionAndHiddenShowRefreshesContext` failed on recentering and duplicate Finder/context reads.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RecentDestinationResolverTests/testValidatesResolvedBookmarkWhileSecurityScopeIsActiveAndBalancesAccess` failed because validation observed no active scope and start/stop counts were zero.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RecentDestinationResolverTests/testStopsScopeAfterInvalidBookmarkBeforeUsingUnscopedLegacyFallback` failed for the same missing bookmark-validation scope.
- An initial plain `swift test` attempt stopped at compilation because the selected toolchain could not import XCTest; all effective test runs explicitly selected `/Applications/Xcode.app/Contents/Developer`.

Green:

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter QuickSendPanelControllerTests` — 9 Swift Testing tests passed.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RecentDestinationResolverTests` — 8 XCTest tests passed.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter QuickSendActionTests.recentDestinationAccessRemainsScopedAcrossAwaitedExport` — 1 Swift Testing test passed.

## Final verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — 196 XCTest tests and 47 Swift Testing tests passed with zero failures.
- `make verify` — built and launched `dist/BarrelMac.app`; process verification succeeded.

## Files

- `Sources/BarrelMac/Support/QuickSendPanelController.swift`
- `Sources/BarrelMac/Services/RecentDestinationResolver.swift`
- `Tests/BarrelMacTests/QuickSendPanelControllerTests.swift`
- `Tests/BarrelMacTests/RecentDestinationResolverTests.swift`
- `Tests/BarrelMacTests/QuickSendActionTests.swift`
- `.superpowers/sdd/quick-send-last-fixes-report.md`

## Concerns

- None known. Scope stops intentionally occur only when `startAccessingSecurityScopedResource()` reports that access began, matching the existing async export behavior.
