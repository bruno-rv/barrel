import BarrelCore
import Combine
import Foundation

@MainActor
final class QuickSendModel: ObservableObject {
  enum AsyncActionOutcome {
    case dismiss
    case keepOpen(warning: String)
  }

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
  private var asyncPrimaryAction: ((QuickSendResult) async throws -> AsyncActionOutcome)?
  private var openHistoryAction: ((HistoryEvent) -> Bool)?
  private var revealHistoryAction: ((HistoryEvent) -> Bool)?
  private var refreshGeneration = 0

  init(
    finderReader: FinderSelectionReading,
    items: @escaping () -> [ShelfItem],
    history: @escaping () -> [HistoryEvent],
    destinations: @escaping () -> [RecentDestination],
    isUndoEligible: @escaping (HistoryEvent) -> Bool,
    performPrimary: @escaping (QuickSendResult) -> Void,
    performAsyncPrimary: ((QuickSendResult) async throws -> AsyncActionOutcome)? = nil,
    openHistory: ((HistoryEvent) -> Bool)? = nil,
    revealHistory: ((HistoryEvent) -> Bool)? = nil,
    dismiss: @escaping () -> Void
  ) {
    self.finderReader = finderReader
    self.items = items
    self.history = history
    self.destinations = destinations
    self.isUndoEligible = isUndoEligible
    primaryAction = performPrimary
    asyncPrimaryAction = performAsyncPrimary
    openHistoryAction = openHistory
    revealHistoryAction = revealHistory
    dismissAction = dismiss
  }

  convenience init(
    store: ShelfStore,
    finderReader: FinderSelectionReading,
    destinationResolver: RecentDestinationResolver,
    dismiss: @escaping () -> Void
  ) {
    self.init(
      finderReader: finderReader,
      items: { store.items },
      history: { store.historyEvents },
      destinations: { destinationResolver.destinations(from: store.historyEvents) },
      isUndoEligible: { store.isUndoEligible($0) },
      performPrimary: { _ in },
      dismiss: dismiss
    )
    asyncPrimaryAction = { result in
      switch result.group {
      case .finderSelection:
        let outcome = await store.importURLsForQuickSend(result.finderURLs)
        if !outcome.failures.isEmpty {
          throw QuickSendActionError(outcome.failures.map(\.message).joined(separator: "\n"))
        }
        return .dismiss
      case .undoLatest:
        guard let event = store.historyEvents.first(where: {
          result.semanticID == "undo:\($0.id)"
        }) else { throw QuickSendActionError("The export is no longer available for Undo.") }
        let outcome = try await store.undoForQuickSend(event)
        if let warning = outcome.warning {
          return .keepOpen(warning: warning)
        }
        return .dismiss
      case .temporary:
        guard let item = store.items.first(where: {
          result.semanticID == "item:\($0.id)"
        }) else { throw QuickSendActionError("The shelf item is no longer available.") }
        guard let destination = destinationResolver.destinations(from: store.historyEvents).first else {
          throw QuickSendActionError("No recent destination is available.")
        }
        _ = try await destinationResolver.withAccess(to: destination) { url in
          try await store.exportForQuickSend(
            itemID: item.id, to: url, fileName: item.fileName ?? item.title
          )
        }
        return .dismiss
      case .history, .destination:
        throw QuickSendActionError("This result cannot be sent.")
      }
    }
    openHistoryAction = { store.openHistoryEvent($0) }
    revealHistoryAction = { store.revealHistoryEvent($0) }
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
    if let asyncPrimaryAction {
      isOperationRunning = true
      Task {
        do {
          let outcome = try await asyncPrimaryAction(selectedResult)
          await refresh()
          switch outcome {
          case .dismiss:
            finishOperation(.success(()))
            dismissAction()
          case .keepOpen(let warning):
            inlineError = warning
            isOperationRunning = false
          }
        } catch {
          finishOperation(.failure(error))
        }
      }
      return
    }
    primaryAction(selectedResult)
  }

  @discardableResult
  func openSelectedHistory() -> Bool {
    performHistoryAction(openHistoryAction)
  }

  @discardableResult
  func revealSelectedHistory() -> Bool {
    performHistoryAction(revealHistoryAction)
  }

  func performSecondary() {
    guard !isOperationRunning, let selectedResult, selectedResult.isSecondaryEnabled else { return }
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
      let encodedPaths = paths.sorted().map { "\($0.utf8.count):\($0)" }.joined()
      return [QuickSendResult(
        semanticID: "finder:\(encodedPaths)",
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
          isPrimaryEnabled: item.kind == .file || item.kind == .image,
          isSecondaryEnabled: item.kind == .file || item.kind == .image
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
        recency: event.timestamp, isPrimaryEnabled: false,
        isSecondaryEnabled: event.destinationURL.map {
          FileManager.default.fileExists(atPath: $0.path)
        } ?? false
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

  private func performHistoryAction(_ action: ((HistoryEvent) -> Bool)?) -> Bool {
    guard !isOperationRunning, let action,
          case let .actions(capturedID) = secondaryMode,
          let capturedResult = results.first(where: {
            $0.semanticID == capturedID && $0.group == .history
          }),
          let event = history().first(where: {
            capturedResult.semanticID == "history:\($0.id)"
          }) else { return false }
    guard action(event) else {
      inlineError = "The exported file is no longer available."
      return false
    }
    inlineError = nil
    return true
  }
}

private struct QuickSendActionError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
