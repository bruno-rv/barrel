import BarrelCore
import Foundation
import Testing
@testable import BarrelMac

@MainActor
struct QuickSendModelTests {
  @Test func ranksGroupsAndPrefixMatchesBeforeSubstringWhilePreservingRecency() async {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let report = item("Report.pdf", kind: .file, updatedAt: now.addingTimeInterval(-2))
    let annual = item("Annual report.pdf", kind: .file, updatedAt: now)
    let history = event(source: "Report.pdf", destination: "Reports", timestamp: now)
    let destination = RecentDestination(
      id: "/Reports", name: "Reports", url: URL(fileURLWithPath: "/Reports"),
      bookmark: nil, lastUsedAt: now
    )
    let model = makeModel(
      finder: .selection([URL(fileURLWithPath: "/Report.pdf")]), items: [annual, report],
      history: [history], destinations: [destination], isUndoEligible: { $0.id == history.id }
    )

    model.setQuery("rep")
    await model.refresh()

    #expect(model.results.map(\.group) == [
      .finderSelection, .undoLatest, .temporary, .temporary, .history, .destination,
    ])
    #expect(model.resultsInGroup(.temporary).map(\.title) == ["Report.pdf", "Annual report.pdf"])
  }

  @Test func emptyQueryIncludesContentAndKindOriginTokensMatchDiacriticInsensitively() async {
    let newest = item("Résumé", kind: .image, origin: .clipboard, updatedAt: Date(timeIntervalSince1970: 2))
    let older = item("Notes", kind: .file, origin: .imported, updatedAt: Date(timeIntervalSince1970: 1))
    let model = makeModel(items: [older, newest])

    await model.refresh()
    #expect(model.resultsInGroup(.temporary).map(\.title) == ["Résumé", "Notes"])

    model.setQuery("resume image clipboard")
    #expect(model.resultsInGroup(.temporary).map(\.title) == ["Résumé"])
  }

  @Test func equalMatchAndRecencyPreserveSourceOrder() async {
    let date = Date(timeIntervalSince1970: 1)
    let first = ShelfItem(
      id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
      title: "First", kind: .file, createdAt: date, updatedAt: date
    )
    let second = ShelfItem(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      title: "Second", kind: .file, createdAt: date, updatedAt: date
    )
    let model = makeModel(items: [first, second])

    await model.refresh()

    #expect(model.resultsInGroup(.temporary).map(\.title) == ["First", "Second"])
  }

  @Test func onlyFileAndImageItemsCanSendButOtherKindsRemainSearchable() async {
    let values = [
      item("File", kind: .file), item("Image", kind: .image), item("Link", kind: .link),
      item("Text", kind: .text), item("Stack", kind: .stack),
    ]
    let model = makeModel(items: values)
    await model.refresh()

    let eligibility = Dictionary(
      uniqueKeysWithValues: model.resultsInGroup(.temporary).map { ($0.title, $0.isPrimaryEnabled) }
    )
    #expect(eligibility == [
      "File": true, "Image": true, "Link": false, "Text": false, "Stack": false,
    ])
  }

  @Test func undoUsesOnlyAuthoritativelyEligibleEventAndReverseEventsAreInformational() async {
    let now = Date(timeIntervalSince1970: 10)
    let stale = event(source: "Stale", timestamp: now.addingTimeInterval(-5))
    let expired = event(source: "Expired", timestamp: now.addingTimeInterval(-4))
    let valid = event(source: "Valid", timestamp: now.addingTimeInterval(-3))
    let nonlatest = event(source: "Nonlatest", timestamp: now.addingTimeInterval(-2))
    let removed = event(source: "Removed", timestamp: now.addingTimeInterval(-1))
    let reverse = event(kind: .undo, source: "Removed", timestamp: now, reversed: removed.id)
    let eligibility = [
      stale.id: false,
      expired.id: false,
      valid.id: true,
      nonlatest.id: false,
      removed.id: false,
    ]
    let model = makeModel(
      history: [stale, expired, valid, nonlatest, removed, reverse],
      isUndoEligible: { eligibility[$0.id] == true }
    )

    await model.refresh()

    #expect(model.resultsInGroup(.undoLatest).single?.semanticID == "undo:\(valid.id)")
    #expect(model.resultsInGroup(.history).count == 6)
    #expect(model.resultsInGroup(.history).first?.isPrimaryEnabled == false)
  }

  @Test func undoIsAbsentWhenAuthoritativeCallerMarksEveryEventIneligible() async {
    let candidate = event(source: "Candidate", timestamp: Date(timeIntervalSince1970: 10))
    let model = makeModel(history: [candidate], isUndoEligible: { _ in false })

    await model.refresh()

    #expect(model.resultsInGroup(.undoLatest).isEmpty)
  }

  @Test func semanticIDsAndSelectionSurviveAsyncFinderRefresh() async {
    let selected = item("Keep", kind: .file)
    let reader = SequencedFinderReader(states: [
      .selection([URL(fileURLWithPath: "/One")]),
      .selection([URL(fileURLWithPath: "/Two")]),
    ])
    let model = makeModel(reader: reader, items: [selected])
    await model.refresh()
    model.selectedResultID = model.resultsInGroup(.temporary).single?.id
    let stableID = model.selectedResultID

    await model.refresh()

    #expect(model.selectedResultID == stableID)
    #expect(model.resultsInGroup(.temporary).single?.id == stableID)
  }

  @Test func olderFinderCompletionCannotOverwriteNewerRefresh() async {
    let reader = ControlledFinderReader()
    let model = makeModel(reader: reader)

    let olderRefresh = Task { await model.refresh() }
    await reader.waitForRequestCount(1)
    let newerRefresh = Task { await model.refresh() }
    await reader.waitForRequestCount(2)

    await reader.completeRequest(at: 1, with: .selection([URL(fileURLWithPath: "/Newer")]))
    await newerRefresh.value
    await reader.completeRequest(at: 0, with: .selection([URL(fileURLWithPath: "/Older")]))
    await olderRefresh.value

    #expect(model.finderState == .selection([URL(fileURLWithPath: "/Newer")]))
    #expect(model.resultsInGroup(.finderSelection).single?.title == "Newer")
  }

  @Test func reorderedFinderSetKeepsSelectionIdentityAndProviderURLOrderForImport() async {
    let a = URL(fileURLWithPath: "/Folder/../A")
    let b = URL(fileURLWithPath: "/B")
    let reader = SequencedFinderReader(states: [
      .selection([a, b]),
      .selection([b, a]),
    ])
    var dispatchedURLs: [URL] = []
    let model = makeModel(reader: reader, primary: { dispatchedURLs = $0.finderURLs })

    await model.refresh()
    let semanticID = model.selectedResultID
    await model.refresh()

    #expect(model.selectedResultID == semanticID)
    #expect(model.resultsInGroup(.finderSelection).single?.finderURLs == [b, a])
    model.performPrimary()
    #expect(dispatchedURLs == [b, a])
  }

  @Test func finderSemanticIDDoesNotCollideWhenPathsContainPipe() async {
    let reader = SequencedFinderReader(states: [
      .selection([URL(fileURLWithPath: "/A|/B"), URL(fileURLWithPath: "/C")]),
      .selection([URL(fileURLWithPath: "/A"), URL(fileURLWithPath: "/B|/C")]),
    ])
    let model = makeModel(reader: reader)

    await model.refresh()
    let firstID = model.resultsInGroup(.finderSelection).single?.semanticID
    await model.refresh()
    let secondID = model.resultsInGroup(.finderSelection).single?.semanticID

    #expect(firstID != secondID)
  }

  @Test func queryFiltersCapturedFinderHistoryAndDestinationSnapshotsWithoutRefreshingSources() async {
    let finderURL = URL(fileURLWithPath: "/Finder/Hold.txt")
    let replacementURL = URL(fileURLWithPath: "/Finder/Replacement.txt")
    let reader = RecordingFinderReader(states: [
      .selection([finderURL]), .selection([replacementURL]),
    ])
    let originalHistory = event(
      source: "History Hold", destination: "Archive", timestamp: Date(timeIntervalSince1970: 2)
    )
    let replacementHistory = event(
      source: "Replacement", destination: "Elsewhere", timestamp: Date(timeIntervalSince1970: 3)
    )
    let originalDestination = RecentDestination(
      id: "/Archive", name: "Archive", url: URL(fileURLWithPath: "/Archive"),
      bookmark: nil, lastUsedAt: Date(timeIntervalSince1970: 2)
    )
    let replacementDestination = RecentDestination(
      id: "/Elsewhere", name: "Elsewhere", url: URL(fileURLWithPath: "/Elsewhere"),
      bookmark: nil, lastUsedAt: Date(timeIntervalSince1970: 3)
    )
    var historySnapshot = [originalHistory]
    var destinationSnapshot = [originalDestination]
    var historyReads = 0
    var destinationReads = 0
    let model = QuickSendModel(
      finderReader: reader, items: { [] },
      history: { historyReads += 1; return historySnapshot },
      destinations: { destinationReads += 1; return destinationSnapshot },
      isUndoEligible: { _ in false }, performPrimary: { _ in }, dismiss: {}
    )

    await model.refresh(finderContext: .finderWasFrontmost)
    let finderResult = try! #require(model.resultsInGroup(.finderSelection).single)
    let finderSemanticID = finderResult.semanticID
    #expect(finderResult.finderURLs == [finderURL])
    let initialHistoryReads = historyReads
    let initialDestinationReads = destinationReads
    historySnapshot = [replacementHistory]
    destinationSnapshot = [replacementDestination]

    model.setQuery("Hold")
    #expect(Set(model.results.map(\.group)) == [.finderSelection, .history])
    model.setQuery("missing")
    #expect(model.results.isEmpty)
    model.setQuery("")

    #expect(await reader.callCount == 1)
    #expect(historyReads == initialHistoryReads)
    #expect(destinationReads == initialDestinationReads)
    #expect(model.finderState == .selection([finderURL]))
    #expect(model.resultsInGroup(.finderSelection).single?.semanticID == finderSemanticID)
    #expect(model.resultsInGroup(.finderSelection).single?.finderURLs == [finderURL])
    #expect(model.resultsInGroup(.history).single?.historyEventID == originalHistory.id)
    #expect(model.resultsInGroup(.destination).single?.destinationID == originalDestination.id)
  }

  @Test func arrowsWrapAndReturnDispatchesPrimary() async {
    var dispatched: [String] = []
    let model = makeModel(items: [item("A", kind: .file), item("B", kind: .file)], primary: {
      dispatched.append($0.semanticID)
    })
    await model.refresh()
    let ids = model.results.map(\.id)

    model.moveSelection(.up)
    #expect(model.selectedResultID == ids.last)
    model.moveSelection(.down)
    #expect(model.selectedResultID == ids.first)
    model.performPrimary()
    #expect(dispatched == [model.selectedResult?.semanticID].compactMap { $0 })
  }

  @Test func commandReturnOpensSecondaryAndEscapeReportsLayersBeforePanel() async {
    var dismissals = 0
    let model = makeModel(items: [item("A", kind: .file)], dismiss: { dismissals += 1 })
    await model.refresh()

    model.performSecondary()
    #expect(model.secondaryMode != nil)
    #expect(model.handleEscape() == .closedLayer)
    #expect(model.secondaryMode == nil)
    #expect(dismissals == 0)
    #expect(model.handleEscape() == .dismissPanel)
    #expect(dismissals == 0)
  }

  @Test func temporaryPrimaryOpensDestinationLayerWithoutDispatchingFirstDestination() async {
    let shelfItem = item("Source", kind: .file)
    let first = RecentDestination(
      id: "/First", name: "First", url: URL(fileURLWithPath: "/First"),
      bookmark: nil, lastUsedAt: Date(timeIntervalSince1970: 2)
    )
    let second = RecentDestination(
      id: "/Second", name: "Second", url: URL(fileURLWithPath: "/Second"),
      bookmark: nil, lastUsedAt: Date(timeIntervalSince1970: 1)
    )
    var exports: [(UUID, String)] = []
    let model = QuickSendModel(
      finderReader: StaticFinderReader(state: .empty), items: { [shelfItem] }, history: { [] },
      destinations: { [first, second] }, isUndoEligible: { _ in false },
      performPrimary: { _ in },
      exportItem: { exports.append(($0, $1.id)); return .dismiss }, dismiss: {}
    )
    await model.refresh()

    model.performPrimary()

    #expect(model.secondaryMode == .destinations(shelfItem.id))
    #expect(model.layerResults.map(\.title) == ["First", "Second"])
    #expect(exports.isEmpty)
    #expect(model.handleEscape() == .closedLayer)
    #expect(model.selectedResultID == "item:\(shelfItem.id)")
  }

  @Test func destinationActivationExportsCapturedItemToExactChosenDestination() async {
    let a = item("A", kind: .file)
    let b = item("B", kind: .file)
    let first = RecentDestination(
      id: "/First", name: "First", url: URL(fileURLWithPath: "/First"),
      bookmark: nil, lastUsedAt: Date(timeIntervalSince1970: 2)
    )
    let second = RecentDestination(
      id: "/Second", name: "Second", url: URL(fileURLWithPath: "/Second"),
      bookmark: nil, lastUsedAt: Date(timeIntervalSince1970: 1)
    )
    var exports: [(UUID, String)] = []
    let model = QuickSendModel(
      finderReader: StaticFinderReader(state: .empty), items: { [a, b] }, history: { [] },
      destinations: { [first, second] }, isUndoEligible: { _ in false },
      performPrimary: { _ in },
      exportItem: { itemID, destination in exports.append((itemID, destination.id)); return .dismiss },
      dismiss: {}
    )
    await model.refresh()
    model.selectedResultID = "item:\(a.id)"
    model.performPrimary()
    model.selectedResultID = "item:\(b.id)"

    model.activateResult("destination:\(second.id)")
    while model.isOperationRunning { await Task.yield() }

    #expect(exports.count == 1)
    #expect(exports.first?.0 == a.id)
    #expect(exports.first?.1 == second.id)
  }

  @Test func itemOnlyQueryStillOpensEveryDestinationAndExportsExactKeyboardChoice() async {
    let shelfItem = item("Quarterly Report", kind: .file)
    let first = RecentDestination(
      id: "/Invoices", name: "Invoices", url: URL(fileURLWithPath: "/Invoices"),
      bookmark: nil, lastUsedAt: Date(timeIntervalSince1970: 2)
    )
    let second = RecentDestination(
      id: "/Archive", name: "Archive", url: URL(fileURLWithPath: "/Archive"),
      bookmark: nil, lastUsedAt: Date(timeIntervalSince1970: 1)
    )
    var exports: [(UUID, String)] = []
    let model = QuickSendModel(
      finderReader: StaticFinderReader(state: .empty), items: { [shelfItem] }, history: { [] },
      destinations: { [first, second] }, isUndoEligible: { _ in false },
      performPrimary: { _ in },
      exportItem: { itemID, destination in exports.append((itemID, destination.id)); return .dismiss },
      dismiss: {}
    )
    model.setQuery("quarterly")
    await model.refresh()

    #expect(model.results.map(\.title) == ["Quarterly Report"])
    model.performPrimary()

    #expect(model.secondaryMode == .destinations(shelfItem.id))
    #expect(model.layerResults.map(\.title) == ["Invoices", "Archive"])
    model.moveSelection(.down)
    model.performPrimary()
    while model.isOperationRunning { await Task.yield() }

    #expect(exports.count == 1)
    #expect(exports.first?.0 == shelfItem.id)
    #expect(exports.first?.1 == second.id)
  }

  @Test func temporaryActionsStayBoundToItemThatOpenedActionLayer() async {
    let a = item("A", kind: .file)
    let b = item("B", kind: .file)
    var opened: [UUID] = []
    var revealed: [UUID] = []
    let model = QuickSendModel(
      finderReader: StaticFinderReader(state: .empty), items: { [a, b] }, history: { [] },
      destinations: { [] }, isUndoEligible: { _ in false }, performPrimary: { _ in },
      openItem: { opened.append($0); return true },
      revealItem: { revealed.append($0); return true }, dismiss: {}
    )
    await model.refresh()
    model.selectedResultID = "item:\(a.id)"
    model.performSecondary()
    model.selectedResultID = "item:\(b.id)"

    #expect(model.openSelectedAction())
    #expect(model.revealSelectedAction())
    #expect(opened == [a.id])
    #expect(revealed == [a.id])
  }

  @Test func informationalHistoryUsesSecondaryCapabilityIndependentlyOfPrimary() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let existingURL = directory.appendingPathComponent("Existing")
    try Data().write(to: existingURL)
    let stale = event(source: "Stale", timestamp: Date(timeIntervalSince1970: 1), destinationURL: existingURL)
    let reverse = event(
      kind: .undo, source: "Reverse", timestamp: Date(timeIntervalSince1970: 2),
      reversed: stale.id, destinationURL: existingURL
    )
    var dispatched: [QuickSendResult.ID] = []
    let model = makeModel(history: [stale, reverse], primary: { dispatched.append($0.id) })
    await model.refresh()

    for event in [stale, reverse] {
      model.selectedResultID = "history:\(event.id)"
      #expect(model.selectedResult?.isPrimaryEnabled == false)
      #expect(model.selectedResult?.isSecondaryEnabled == true)
      model.performPrimary()
      #expect(dispatched.isEmpty)
      model.performSecondary()
      #expect(model.secondaryMode == .actions("history:\(event.id)"))
      #expect(model.handleEscape() == .closedLayer)
    }
  }

  @Test func missingHistoryDestinationDisablesSecondaryAction() async {
    let missingURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    let history = event(
      source: "Missing", timestamp: Date(timeIntervalSince1970: 1), destinationURL: missingURL
    )
    let model = makeModel(history: [history])
    await model.refresh()
    model.selectedResultID = "history:\(history.id)"

    #expect(model.selectedResult?.isSecondaryEnabled == false)
    model.performSecondary()
    #expect(model.secondaryMode == nil)
  }

  @Test func historyActionsRemainBoundToResultThatOpenedSecondaryMode() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let aURL = directory.appendingPathComponent("A")
    let bURL = directory.appendingPathComponent("B")
    try Data().write(to: aURL)
    try Data().write(to: bURL)
    let a = event(
      source: "A", timestamp: Date(timeIntervalSince1970: 2), destinationURL: aURL
    )
    let b = event(
      source: "B", timestamp: Date(timeIntervalSince1970: 1), destinationURL: bURL
    )
    var opened: [UUID] = []
    var revealed: [UUID] = []
    let model = makeModel(
      history: [a, b],
      openHistory: { opened.append($0.id); return true },
      revealHistory: { revealed.append($0.id); return true }
    )
    await model.refresh()
    model.selectedResultID = "history:\(a.id)"
    model.performSecondary()
    model.selectedResultID = "history:\(b.id)"

    #expect(model.openSelectedHistory())
    #expect(model.revealSelectedHistory())
    #expect(opened == [a.id])
    #expect(revealed == [a.id])
  }

  @Test func runningAsyncPrimaryBlocksHistoryActions() async {
    let history = event(source: "History", timestamp: Date(timeIntervalSince1970: 1))
    let shelfItem = item("Source", kind: .file)
    let gate = AsyncActionGate()
    var opened: [UUID] = []
    let model = QuickSendModel(
      finderReader: StaticFinderReader(state: .empty),
      items: { [shelfItem] }, history: { [history] }, destinations: { [] },
      isUndoEligible: { _ in false }, performPrimary: { _ in },
      performAsyncPrimary: { _ in
        await gate.wait()
        return .dismiss
      },
      openHistory: { opened.append($0.id); return true },
      dismiss: {}
    )
    await model.refresh()
    model.selectedResultID = "history:\(history.id)"
    model.performSecondary()
    model.selectedResultID = "item:\(shelfItem.id)"

    model.performPrimary()
    #expect(model.isOperationRunning)
    model.selectedResultID = "history:\(history.id)"
    #expect(!model.openSelectedAction())
    #expect(opened.isEmpty)
    await gate.resume()
    while model.isOperationRunning { await Task.yield() }
  }

  @Test func permissionDenialDisablesOnlyFinderImportAndExposesPermissionState() async {
    let model = makeModel(finder: .permissionDenied, items: [item("A", kind: .file)])
    await model.refresh()

    #expect(model.finderPermissionDenied)
    #expect(model.resultsInGroup(.finderSelection).single?.isPrimaryEnabled == false)
    #expect(model.resultsInGroup(.temporary).single?.isPrimaryEnabled == true)
  }

  @Test func runningOperationGuardsDismissalAndFailureBecomesInlineError() async {
    var dismissals = 0
    let model = makeModel(items: [item("A", kind: .file)], dismiss: { dismissals += 1 })
    await model.refresh()
    model.isOperationRunning = true
    #expect(model.handleEscape() == .blocked)
    #expect(dismissals == 0)

    model.finishOperation(.failure(TestFailure()))
    #expect(!model.isOperationRunning)
    #expect(model.inlineError == "Failed")
  }

  @Test func committedWarningOutcomeKeepsSelectionQueryAndPanelOpen() async {
    let shelfItem = item("Source.txt", kind: .file)
    var dismissals = 0
    let model = QuickSendModel(
      finderReader: StaticFinderReader(state: .empty),
      items: { [shelfItem] }, history: { [] }, destinations: { [] },
      isUndoEligible: { _ in false }, performPrimary: { _ in },
      performAsyncPrimary: { _ in
        .keepOpen(warning: "Undo was saved with a cleanup warning.")
      },
      dismiss: { dismissals += 1 }
    )
    model.setQuery("source")
    await model.refresh()
    let selection = model.selectedResultID

    model.performPrimary()
    while model.isOperationRunning { await Task.yield() }

    #expect(dismissals == 0)
    #expect(model.query == "source")
    #expect(model.selectedResultID == selection)
    #expect(model.inlineError == "Undo was saved with a cleanup warning.")
  }

  private func makeModel(
    finder: FinderSelectionState = .empty,
    reader: FinderSelectionReading? = nil,
    items: [ShelfItem] = [],
    history: [HistoryEvent] = [],
    destinations: [RecentDestination] = [],
    isUndoEligible: @escaping (HistoryEvent) -> Bool = { _ in false },
    primary: @escaping (QuickSendResult) -> Void = { _ in },
    openHistory: ((HistoryEvent) -> Bool)? = nil,
    revealHistory: ((HistoryEvent) -> Bool)? = nil,
    dismiss: @escaping () -> Void = {}
  ) -> QuickSendModel {
    QuickSendModel(
      finderReader: reader ?? StaticFinderReader(state: finder),
      items: { items }, history: { history }, destinations: { destinations },
      isUndoEligible: isUndoEligible,
      performPrimary: primary, openHistory: openHistory, revealHistory: revealHistory,
      dismiss: dismiss
    )
  }

  private func item(
    _ title: String, kind: ShelfKind, origin: ShelfOrigin = .imported,
    updatedAt: Date = .now
  ) -> ShelfItem {
    ShelfItem(title: title, kind: kind, createdAt: updatedAt, updatedAt: updatedAt, origin: origin)
  }

  private func event(
    kind: HistoryEventKind = .export, source: String,
    destination: String = "Desktop", timestamp: Date,
    reversed: UUID? = nil, reversedBy: UUID? = nil,
    destinationURL: URL? = nil
  ) -> HistoryEvent {
    HistoryEvent(
      itemID: UUID(), kind: kind, sourceName: source, destinationName: destination,
      destinationURL: destinationURL ?? URL(fileURLWithPath: "/\(destination)/\(source)"),
      destinationBookmark: nil, fileName: source, contentHash: "hash", timestamp: timestamp,
      reversedEventID: reversed, reversedByEventID: reversedBy
    )
  }
}

private struct StaticFinderReader: FinderSelectionReading {
  let state: FinderSelectionState
  func readSelection(context: FinderSelectionContext) async -> FinderSelectionState { state }
}

private actor SequencedFinderReader: FinderSelectionReading {
  private var states: [FinderSelectionState]
  init(states: [FinderSelectionState]) { self.states = states }
  func readSelection(context: FinderSelectionContext) -> FinderSelectionState { states.removeFirst() }
}

private actor RecordingFinderReader: FinderSelectionReading {
  private var states: [FinderSelectionState]
  private(set) var callCount = 0

  init(states: [FinderSelectionState]) { self.states = states }

  func readSelection(context: FinderSelectionContext) -> FinderSelectionState {
    callCount += 1
    return states.removeFirst()
  }
}

private actor ControlledFinderReader: FinderSelectionReading {
  private var continuations: [CheckedContinuation<FinderSelectionState, Never>] = []

  func readSelection(context: FinderSelectionContext) async -> FinderSelectionState {
    await withCheckedContinuation { continuations.append($0) }
  }

  func waitForRequestCount(_ count: Int) async {
    while continuations.count < count { await Task.yield() }
  }

  func completeRequest(at index: Int, with state: FinderSelectionState) {
    continuations[index].resume(returning: state)
  }
}

private struct TestFailure: LocalizedError {
  var errorDescription: String? { "Failed" }
}

private actor AsyncActionGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isReleased = false

  func wait() async {
    guard !isReleased else { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func resume() {
    isReleased = true
    continuation?.resume()
    continuation = nil
  }
}

private extension Array {
  var single: Element? { count == 1 ? first : nil }
}
