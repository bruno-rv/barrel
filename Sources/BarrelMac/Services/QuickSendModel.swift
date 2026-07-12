import BarrelCore
import Combine
import Foundation

@MainActor
final class QuickSendModel: ObservableObject {
  enum SelectionDirection {
    case up
    case down
  }

  enum SecondaryMode: Equatable {
    case actions(QuickSendResult.ID)
  }

  @Published var query = ""
  @Published private(set) var results: [QuickSendResult] = []
  @Published var selectedResultID: QuickSendResult.ID?
  @Published private(set) var finderState: FinderSelectionState = .unavailable
  @Published private(set) var secondaryMode: SecondaryMode?
  @Published private(set) var inlineError: String?
  @Published var isOperationRunning = false

  private let finderReader: FinderSelectionReading
  private let items: () -> [ShelfItem]
  private let history: () -> [HistoryEvent]
  private let destinations: () -> [RecentDestination]
  private let isUndoEligible: (HistoryEvent) -> Bool
  private let primaryAction: (QuickSendResult) -> Void
  private let dismissAction: () -> Void
  private var refreshGeneration = 0

  init(
    finderReader: FinderSelectionReading,
    items: @escaping () -> [ShelfItem],
    history: @escaping () -> [HistoryEvent],
    destinations: @escaping () -> [RecentDestination],
    isUndoEligible: @escaping (HistoryEvent) -> Bool,
    performPrimary: @escaping (QuickSendResult) -> Void,
    dismiss: @escaping () -> Void
  ) {
    self.finderReader = finderReader
    self.items = items
    self.history = history
    self.destinations = destinations
    self.isUndoEligible = isUndoEligible
    primaryAction = performPrimary
    dismissAction = dismiss
  }

  var selectedResult: QuickSendResult? {
    selectedResultID.flatMap { id in results.first { $0.id == id } }
  }

  var finderPermissionDenied: Bool {
    finderState == .permissionDenied
  }

  func resultsInGroup(_ group: QuickSendResultGroup) -> [QuickSendResult] {
    results.filter { $0.group == group }
  }

  func refresh() async {
    refreshGeneration &+= 1
    let generation = refreshGeneration
    let previousSelection = selectedResultID
    let refreshedFinderState = await finderReader.readSelection()
    guard generation == refreshGeneration else { return }
    finderState = refreshedFinderState

    let candidates = finderResults()
      + undoResults()
      + temporaryResults()
      + historyResults()
      + destinationResults()
    results = candidates.enumerated()
      .compactMap { index, result in matchRank(for: result).map { (result, $0, index) } }
      .sorted { lhs, rhs in
        if lhs.0.group.rawValue != rhs.0.group.rawValue {
          return lhs.0.group.rawValue < rhs.0.group.rawValue
        }
        if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
        if lhs.0.recency != rhs.0.recency { return lhs.0.recency > rhs.0.recency }
        return lhs.2 < rhs.2
      }
      .map(\.0)

    if let previousSelection, results.contains(where: { $0.id == previousSelection }) {
      selectedResultID = previousSelection
    } else {
      selectedResultID = results.first?.id
    }
  }

  func moveSelection(_ direction: SelectionDirection) {
    guard !results.isEmpty else {
      selectedResultID = nil
      return
    }
    guard let selectedResultID,
          let index = results.firstIndex(where: { $0.id == selectedResultID })
    else {
      self.selectedResultID = direction == .down ? results.first?.id : results.last?.id
      return
    }
    let offset = direction == .down ? 1 : -1
    self.selectedResultID = results[(index + offset + results.count) % results.count].id
  }

  func performPrimary() {
    guard !isOperationRunning, let selectedResult, selectedResult.isPrimaryEnabled else { return }
    inlineError = nil
    primaryAction(selectedResult)
  }

  func performSecondary() {
    guard !isOperationRunning, let selectedResult, selectedResult.isPrimaryEnabled else { return }
    secondaryMode = .actions(selectedResult.id)
  }

  @discardableResult
  func handleEscape() -> Bool {
    guard !isOperationRunning else { return false }
    if secondaryMode != nil {
      secondaryMode = nil
    } else {
      dismissAction()
    }
    return true
  }

  func finishOperation(_ result: Result<Void, Error>) {
    isOperationRunning = false
    switch result {
    case .success:
      inlineError = nil
    case let .failure(error):
      inlineError = error.localizedDescription
    }
  }

  private func finderResults() -> [QuickSendResult] {
    switch finderState {
    case let .selection(urls):
      guard !urls.isEmpty else { return [] }
      let paths = urls.map { $0.standardizedFileURL.path }
      return [QuickSendResult(
        semanticID: "finder:\(paths.sorted().joined(separator: "|"))",
        group: .finderSelection,
        title: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) Finder Items",
        subtitle: "Finder Selection",
        searchTerms: paths,
        finderURLs: urls,
        isPrimaryEnabled: true
      )]
    case .permissionDenied:
      return [QuickSendResult(
        semanticID: "finder:permission-denied", group: .finderSelection,
        title: "Allow Finder Access", subtitle: "Finder Automation permission is required",
        searchTerms: ["finder", "permission", "automation"], isPrimaryEnabled: false
      )]
    case .empty, .unavailable:
      return []
    }
  }

  private func undoResults() -> [QuickSendResult] {
    guard let event = history()
      .filter(isUndoEligible)
      .max(by: { $0.timestamp < $1.timestamp })
    else { return [] }
    return [QuickSendResult(
      semanticID: "undo:\(event.id)", group: .undoLatest,
      title: "Undo \(event.sourceName)", subtitle: event.destinationName,
      searchTerms: ["undo", event.fileName, event.destinationName],
      recency: event.timestamp, isPrimaryEnabled: true
    )]
  }

  private func temporaryResults() -> [QuickSendResult] {
    items()
      .filter { $0.trashedAt == nil && $0.deletedAt == nil }
      .map { item in
        QuickSendResult(
          semanticID: "item:\(item.id)", group: .temporary, title: item.title,
          subtitle: item.detail,
          searchTerms: [item.detail, item.text ?? "", item.kind.rawValue, item.kind.label, item.origin.rawValue],
          recency: item.updatedAt,
          isPrimaryEnabled: item.kind == .file || item.kind == .image
        )
      }
  }

  private func historyResults() -> [QuickSendResult] {
    history().map { event in
      QuickSendResult(
        semanticID: "history:\(event.id)", group: .history,
        title: event.kind == .undo ? "Undid \(event.sourceName)" : event.sourceName,
        subtitle: event.destinationName,
        searchTerms: [event.kind.rawValue, event.fileName, event.destinationName],
        recency: event.timestamp, isPrimaryEnabled: false
      )
    }
  }

  private func destinationResults() -> [QuickSendResult] {
    destinations().map { destination in
      QuickSendResult(
        semanticID: "destination:\(destination.id)", group: .destination,
        title: destination.name, subtitle: destination.url.path,
        searchTerms: [destination.url.path], recency: destination.lastUsedAt,
        isPrimaryEnabled: false
      )
    }
  }

  private func matchRank(for result: QuickSendResult) -> Int? {
    let tokens = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
    guard !tokens.isEmpty else { return 0 }
    let fields = ([result.title, result.subtitle ?? ""] + result.searchTerms).map(normalized)
    var rank = 0
    for token in tokens {
      if fields.contains(where: { $0.hasPrefix(token) }) {
        continue
      }
      if fields.contains(where: { $0.contains(token) }) {
        rank = 1
        continue
      }
      return nil
    }
    return rank
  }

  private func normalized(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }
}
