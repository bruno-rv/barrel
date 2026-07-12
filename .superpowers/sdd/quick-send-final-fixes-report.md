# Quick Send Final Fixes Report

## Scope

- Keep Quick Send open after a partial Finder import, refresh store-derived results, consume the captured Finder selection, retain query/selection when possible, and show the failure inline.
- Model Open and Reveal as explicit capabilities independent of send eligibility and route actions through the captured result ID.
- Use the exact Finder action labels `Hold 1 Finder Item` and `Hold N Finder Items`.

## TDD evidence

### Red

Command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'QuickSend(Model|Action)Tests'
```

The new tests failed before production support existed. The compiler reported that `QuickSendResult` had no `availableActions` member and could not resolve the `.open` and `.reveal` capabilities. The initial run also identified a test-only cross-file `fileprivate` helper use, which was corrected to use `first` before implementation proceeded.

### Green

The same focused command passed 38 tests across `QuickSendModelTests` and `QuickSendActionTests`, including the production-wired one-file/one-folder partial import regression.

## Implementation

- Partial Finder import returns a keep-open outcome carrying whether the captured selection should be consumed. The normal async refresh updates shelf items, history, and destinations; consuming the Finder capture then recomputes without rereading Finder, preventing a duplicate retry.
- Query and semantic-ID selection preservation continue through the existing result recomputation path. If the Finder result disappears, selection falls back to the first matching refreshed result.
- `QuickSendResult.availableActions` explicitly represents `.open` and `.reveal`; `isSecondaryEnabled` is derived from that set. Files/images expose both, links expose Open only, and text/stacks expose neither.
- The action UI renders only captured-result capabilities, and dispatch validates the requested capability against that same captured result before routing its item/history ID.
- Finder labels now use the required singular/plural copy.

## Verification

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Passed: 194 XCTest tests plus 46 Swift Testing tests, zero failures.

```sh
make verify
```

Passed: built and verified `dist/BarrelMac.app`.

```sh
git diff --check
```

Passed with no whitespace errors.

## Concerns

- No known functional concerns. All-failure Finder imports intentionally retain the captured Finder action; only partial success consumes it because successful content was actually held.
- The non-Xcode `swift test` invocation cannot locate XCTest in this environment, so verification uses the repository-documented `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` form.
