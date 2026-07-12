import AppKit
import SwiftUI

private enum QuickSendCommand {
  case up, down, primary, secondary, escape
}

struct QuickSendView: View {
  @ObservedObject var model: QuickSendModel
  let registerSearchField: (NSSearchField) -> Void
  let dismiss: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      QuickSendSearchField(
        text: $model.query,
        register: registerSearchField,
        command: handleCommand
      )
      .frame(height: 28)
      .accessibilityLabel("Quick Send search")
      .onChange(of: model.query) { Task { await model.refresh() } }

      if model.finderPermissionDenied {
        HStack {
          Label("Finder access is disabled.", systemImage: "lock.trianglebadge.exclamationmark")
          Spacer()
          Button("Open Privacy Settings") { openAutomationSettings() }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
      }

      if let error = model.inlineError {
        Text(error).foregroundStyle(.red).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("Quick Send error: \(error)")
      }

      ScrollView {
        LazyVStack(spacing: 8) {
          ForEach(QuickSendResultGroup.allCases, id: \.rawValue) { group in
            let results = model.layerResults.filter { $0.group == group }
            if !results.isEmpty {
              Section(group.title) {
                ForEach(results) { result in resultRow(result) }
              }
            }
          }
        }
      }
      .overlay {
        if model.results.isEmpty && !model.isOperationRunning {
          ContentUnavailableView.search(text: model.query)
        }
      }

      if model.isOperationRunning {
        ProgressView("Working…").controlSize(.small).accessibilityLabel("Quick Send operation in progress")
      }
    }
    .padding(14)
    .frame(width: 520, height: 460)
    .background(.regularMaterial)
  }

  private func resultRow(_ result: QuickSendResult) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(result.title).fontWeight(.medium).lineLimit(1)
          if let subtitle = result.subtitle {
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Spacer()
        if result.isPrimaryEnabled || (result.group == .destination && model.isChoosingDestination) {
          Button(result.group == .temporary ? "Destinations" : "Activate") {
            model.activateResult(result.id)
          }
          .buttonStyle(.borderless)
        }
      }
      if model.secondaryMode == .actions(result.id) {
        HStack {
          Button("Open") { _ = model.openSelectedAction() }
          Button("Reveal in Finder") { _ = model.revealSelectedAction() }
        }.buttonStyle(.bordered)
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(result.id == model.selectedResultID ? Color.accentColor.opacity(0.18) : Color.clear)
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { model.activateResult(result.id) }
    .simultaneousGesture(TapGesture(count: 1).onEnded { model.selectResult(result.id) })
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: "Activate") { model.activateResult(result.id) }
    .accessibilityAddTraits(result.id == model.selectedResultID ? .isSelected : [])
  }

  private func handleCommand(_ command: QuickSendCommand) {
    switch command {
    case .up: model.moveSelection(.up)
    case .down: model.moveSelection(.down)
    case .primary: model.performPrimary()
    case .secondary: model.performSecondary()
    case .escape:
      QuickSendEscapeRouter.route(model: model, dismiss: dismiss)
    }
  }

  private func openAutomationSettings() {
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    NSWorkspace.shared.open(url)
  }
}

private extension QuickSendResultGroup {
  var title: String {
    switch self {
    case .finderSelection: "Finder"
    case .undoLatest: "Undo"
    case .temporary: "Shelf"
    case .history: "History"
    case .destination: "Recent Destinations"
    }
  }
}

private struct QuickSendSearchField: NSViewRepresentable {
  @Binding var text: String
  let register: (NSSearchField) -> Void
  let command: (QuickSendCommand) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeNSView(context: Context) -> NSSearchField {
    let field = CommandSearchField()
    field.placeholderString = "Search shelf, History, and destinations"
    field.delegate = context.coordinator
    field.command = command
    register(field)
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    if field.stringValue != text { field.stringValue = text }
    (field as? CommandSearchField)?.command = command
    context.coordinator.parent = self
  }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: QuickSendSearchField
    init(parent: QuickSendSearchField) { self.parent = parent }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      parent.text = field.stringValue
    }
  }

  final class CommandSearchField: NSSearchField {
    var command: ((QuickSendCommand) -> Void)?
    override func keyDown(with event: NSEvent) {
      let mapped: QuickSendCommand?
      switch event.keyCode {
      case 126: mapped = .up
      case 125: mapped = .down
      case 36, 76: mapped = event.modifierFlags.contains(.command) ? .secondary : .primary
      case 53: mapped = .escape
      default: mapped = nil
      }
      if let mapped { command?(mapped) } else { super.keyDown(with: event) }
    }
  }
}
