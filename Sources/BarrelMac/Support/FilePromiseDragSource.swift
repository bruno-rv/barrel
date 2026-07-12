import AppKit
import BarrelCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
protocol ShelfFilePromiseExporting: AnyObject {
  func export(itemID: UUID, to directoryURL: URL) async throws -> HistoryEvent
}

final class ShelfFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
  private let itemID: UUID
  private let fileName: String
  private let exporter: any ShelfFilePromiseExporting
  private let didEnd: @MainActor () -> Void

  @MainActor
  init(
    itemID: UUID,
    fileName: String,
    exporter: any ShelfFilePromiseExporting,
    didEnd: @escaping @MainActor () -> Void = {}
  ) {
    self.itemID = itemID
    self.fileName = fileName
    self.exporter = exporter
    self.didEnd = didEnd
  }

  func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider,
    fileNameForType fileType: String
  ) -> String {
    fileName
  }

  func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider,
    writePromiseTo url: URL,
    completionHandler: @escaping (Error?) -> Void
  ) {
    Task { @MainActor [self] in
      do {
        _ = try await exporter.export(itemID: itemID, to: url)
        completionHandler(nil)
      } catch {
        completionHandler(error)
      }
    }
  }

  func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider,
    operationEnded error: (any Error)?
  ) {
    Task { @MainActor [self] in didEnd() }
  }
}

struct FilePromiseDragSource<Content: View>: NSViewRepresentable {
  let itemID: UUID
  let fileName: String
  let exporter: any ShelfFilePromiseExporting
  @ViewBuilder let content: () -> Content

  func makeCoordinator() -> Coordinator {
    Coordinator(itemID: itemID, fileName: fileName, exporter: exporter)
  }

  func makeNSView(context: Context) -> NSHostingView<Content> {
    let hostingView = NSHostingView(rootView: content())
    context.coordinator.install(on: hostingView)
    return hostingView
  }

  func updateNSView(_ nsView: NSHostingView<Content>, context: Context) {
    nsView.rootView = content()
    context.coordinator.update(itemID: itemID, fileName: fileName, exporter: exporter)
  }

  @MainActor
  final class Coordinator: NSObject, NSDraggingSource, NSGestureRecognizerDelegate {
    private var itemID: UUID
    private var fileName: String
    private weak var exporter: (any ShelfFilePromiseExporting)?
    private weak var view: NSView?
    private var promiseDelegate: ShelfFilePromiseDelegate?

    init(itemID: UUID, fileName: String, exporter: any ShelfFilePromiseExporting) {
      self.itemID = itemID
      self.fileName = fileName
      self.exporter = exporter
    }

    func update(itemID: UUID, fileName: String, exporter: any ShelfFilePromiseExporting) {
      self.itemID = itemID
      self.fileName = fileName
      self.exporter = exporter
    }

    func install(on view: NSView) {
      self.view = view
      let recognizer = NSPanGestureRecognizer(target: self, action: #selector(beginDrag(_:)))
      recognizer.delegate = self
      view.addGestureRecognizer(recognizer)
    }

    func gestureRecognizer(
      _ gestureRecognizer: NSGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
      true
    }

    @objc private func beginDrag(_ recognizer: NSPanGestureRecognizer) {
      guard recognizer.state == .began,
            let view,
            let exporter,
            let event = NSApp.currentEvent else { return }

      let fileType = UTType(filenameExtension: (fileName as NSString).pathExtension)?.identifier
        ?? UTType.data.identifier
      let delegate = ShelfFilePromiseDelegate(
        itemID: itemID,
        fileName: fileName,
        exporter: exporter,
        didEnd: { [weak self] in self?.promiseDelegate = nil }
      )
      promiseDelegate = delegate
      let provider = NSFilePromiseProvider(fileType: fileType, delegate: delegate)
      let draggingItem = NSDraggingItem(pasteboardWriter: provider)
      let image = NSWorkspace.shared.icon(for: UTType(fileType) ?? .data)
      let origin = recognizer.location(in: view)
      draggingItem.setDraggingFrame(
        NSRect(x: origin.x - 24, y: origin.y - 24, width: 48, height: 48),
        contents: image
      )
      view.beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    nonisolated func draggingSession(
      _ session: NSDraggingSession,
      sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
      context == .outsideApplication ? .copy : []
    }
  }
}
