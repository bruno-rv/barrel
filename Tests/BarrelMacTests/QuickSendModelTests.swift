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
      finder: .selection([URL(fileURLWithPath: "/Report.pdf")]),
      items: [annual, report], history: [history], destinations: [destination]
    )

    model.query = "rep"
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

    model.query = "resume image clipboard"
    await model.refresh()
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

  @Test func undoUsesLatestEligibleExportAndReverseEventsAreInformational() async {
    let now = Date(timeIntervalSince1970: 10)
    let older = event(source: "Older", timestamp: now.addingTimeInterval(-2))
    let reversedID = UUID()
    let newer = event(source: "Newer", timestamp: now, reversedBy: reversedID)
    let reverse = event(kind: .undo, source: "Newer", timestamp: now.addingTimeInterval(1), reversed: newer.id)
    let model = makeModel(history: [older, newer, reverse])

    await model.refresh()

    #expect(model.resultsInGroup(.undoLatest).single?.semanticID == "undo:\(older.id)")
    #expect(model.resultsInGroup(.history).count == 3)
    #expect(model.resultsInGroup(.history).first?.isPrimaryEnabled == false)
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

  @Test func arrowsWrapAndReturnDispatchesPrimary() async {
    var dispatched: [String] = []
    let model = makeModel(items: [item("A", kind: .file), item("B", kind: .file)]) {
      dispatched.append($0.semanticID)
    }
    await model.refresh()
    let ids = model.results.map(\.id)

    model.moveSelection(.up)
    #expect(model.selectedResultID == ids.last)
    model.moveSelection(.down)
    #expect(model.selectedResultID == ids.first)
    model.performPrimary()
    #expect(dispatched == [model.selectedResult?.semanticID].compactMap { $0 })
  }

  @Test func commandReturnOpensSecondaryAndEscapeClosesLayersBeforePanel() async {
    var dismissals = 0
    let model = makeModel(items: [item("A", kind: .file)], dismiss: { dismissals += 1 })
    await model.refresh()

    model.performSecondary()
    #expect(model.secondaryMode != nil)
    #expect(model.handleEscape())
    #expect(model.secondaryMode == nil)
    #expect(dismissals == 0)
    #expect(model.handleEscape())
    #expect(dismissals == 1)
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
    #expect(!model.handleEscape())
    #expect(dismissals == 0)

    model.finishOperation(.failure(TestFailure()))
    #expect(!model.isOperationRunning)
    #expect(model.inlineError == "Failed")
  }

  private func makeModel(
    finder: FinderSelectionState = .empty,
    reader: FinderSelectionReading? = nil,
    items: [ShelfItem] = [],
    history: [HistoryEvent] = [],
    destinations: [RecentDestination] = [],
    primary: @escaping (QuickSendResult) -> Void = { _ in },
    dismiss: @escaping () -> Void = {}
  ) -> QuickSendModel {
    QuickSendModel(
      finderReader: reader ?? StaticFinderReader(state: finder),
      items: { items }, history: { history }, destinations: { destinations },
      performPrimary: primary, dismiss: dismiss
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
    reversed: UUID? = nil, reversedBy: UUID? = nil
  ) -> HistoryEvent {
    HistoryEvent(
      itemID: UUID(), kind: kind, sourceName: source, destinationName: destination,
      destinationURL: URL(fileURLWithPath: "/\(destination)/\(source)"),
      destinationBookmark: nil, fileName: source, contentHash: "hash", timestamp: timestamp,
      reversedEventID: reversed, reversedByEventID: reversedBy
    )
  }
}

private struct StaticFinderReader: FinderSelectionReading {
  let state: FinderSelectionState
  func readSelection() async -> FinderSelectionState { state }
}

private actor SequencedFinderReader: FinderSelectionReading {
  private var states: [FinderSelectionState]
  init(states: [FinderSelectionState]) { self.states = states }
  func readSelection() -> FinderSelectionState { states.removeFirst() }
}

private struct TestFailure: LocalizedError {
  var errorDescription: String? { "Failed" }
}

private extension Array {
  var single: Element? { count == 1 ? first : nil }
}
