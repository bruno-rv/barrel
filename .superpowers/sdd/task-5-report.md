# Quick Send Task 5 Report

## Status

Complete. Initial commit: `d62a747` (`feat: rank Quick Send commands`).

Follow-up hardening was completed on 2026-07-12; its commit is recorded below.

## Files

- `Sources/BarrelMac/Models/QuickSendResult.swift`
- `Sources/BarrelMac/Services/QuickSendModel.swift`
- `Tests/BarrelMacTests/QuickSendModelTests.swift`

## Implementation

- Added fixed Quick Send result groups in the required order: Finder selection,
  latest Undo, temporary shelf items, history, and recent destinations.
- Defined result IDs from semantic identity rather than result position: Finder
  paths, item IDs, history/Undo event IDs, and destination IDs.
- Added localized case- and diacritic-insensitive token matching across titles,
  subtitles, item kind/origin, file details, history metadata, and destination
  paths.
- Ranked matches group-first, then prefix before substring, then source recency;
  exact recency ties retain provider order.
- Preserved selected semantic IDs across asynchronous Finder refreshes when the
  selected result remains present.
- Included empty-query content and kept text, link, and stack items searchable
  while enabling primary send only for file and image shelf items.
- Exposed Finder selection/import, latest unreversed export Undo, informational
  history/reverse events, and search-only destination eligibility.
- Added wrapping Up/Down selection, primary Return dispatch, Command-Return
  secondary action state, and layered Escape behavior that closes secondary
  state before dismissing the panel.
- Added Finder Automation permission presentation that disables only Finder
  import, plus inline operation errors and dismissal guards while an operation
  is running.
- Routed behavior through injected primary-action and dismissal closures. No
  `ShelfStore` integration was added; that remains Task 6 work.

## TDD evidence

### Initial red

Command:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter QuickSendModelTests
```

Result: expected compile failure because `QuickSendModel` and
`QuickSendResult` did not exist.

### Ranking tie red

After the initial implementation, an explicit equal-match/equal-recency test
failed because the model used semantic UUID order as a final tie-breaker. The
implementation was corrected to retain source order.

### Final green

Command:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter QuickSendModelTests
```

Result: 10 tests passed, 0 failures. The final fresh run completed immediately
before commit. `git diff --cached --check` also passed.

## Self-review

- Confirmed all changes are confined to the three Task 5 files.
- Confirmed semantic IDs do not depend on array offsets.
- Confirmed ranking uses the required group/match/recency precedence and stable
  source-order ties.
- Confirmed permission denial affects Finder import only.
- Confirmed disabled/search-only results cannot dispatch primary or secondary
  actions.
- Confirmed operation-running state prevents Return, Command-Return, and Escape
  dismissal.
- Confirmed no store wiring or unrelated cleanup was introduced.

## Commit

`d62a747 feat: rank Quick Send commands`

Three files changed, 485 insertions.

## Concerns

Task 6 still needs to connect the injected actions and model inputs to
`ShelfStore` and the Quick Send panel UI.

## Follow-up hardening

- Undo candidates now pass through an injected authoritative eligibility
  predicate. Quick Send no longer reconstructs repository eligibility from
  partial History fields.
- Tests cover caller-rejected stale, expired, nonlatest, and removed events,
  an accepted valid event, and the all-ineligible case.
- Refreshes use a monotonically increasing generation. A deterministic
  continuation-controlled test completes two overlapping Finder reads in
  reverse order and confirms the older completion cannot overwrite state or
  results.
- Finder semantic identity is based on sorted standardized paths, so a provider
  reorder preserves selection. `QuickSendResult.finderURLs` retains the exact
  latest provider order for the import action.

### Follow-up TDD evidence

RED command:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter QuickSendModelTests
```

The build failed as expected because `QuickSendResult.finderURLs` and the
`QuickSendModel.isUndoEligible` initializer seam did not exist. After the
minimal implementation, the first run found one legacy fixture that had not
authoritatively marked its expected Undo result eligible; the fixture was
corrected to make that contract explicit.

GREEN command:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter QuickSendModelTests
```

Result: 13 tests passed, 0 failures.

Follow-up commit: created with this report; see the repository history and
worker handoff for its hash.
