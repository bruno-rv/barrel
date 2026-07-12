import AppKit
import BarrelCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
protocol ShelfFilePromiseExporting: AnyObject {
  func export(itemID: UUID, to directoryURL: URL, fileName: String) async throws -> HistoryEvent
}

@MainActor
final class FilePromiseDragLifecycle {
  // An accepted Finder drag may never call writePromiseTo. There is no safe
  // timeout: Finder can begin a valid promise write after an arbitrary delay.
  // The lifecycle/coordinator's deinit is the terminal release for that case.
  private struct SessionState {
    var delegate: ShelfFilePromiseDelegate?
    var writeInProgress = false
    var writeCompleted = false
    var sessionEnded = false
  }

  private var sessions: [UUID: SessionState] = [:]

  func begin(delegate: ShelfFilePromiseDelegate) {
    sessions[delegate.lifecycleID] = SessionState(delegate: delegate)
  }

  func promiseWriteBegan(sessionID: UUID) {
    sessions[sessionID]?.writeInProgress = true
    sessions[sessionID]?.writeCompleted = false
  }

  func promiseWriteEnded(sessionID: UUID) {
    sessions[sessionID]?.writeInProgress = false
    sessions[sessionID]?.writeCompleted = true
    if sessions[sessionID]?.sessionEnded == true { sessions[sessionID] = nil }
  }

  func draggingSessionEnded(sessionID: UUID, operation: NSDragOperation) {
    sessions[sessionID]?.sessionEnded = true
    guard let session = sessions[sessionID] else { return }
    if !session.writeInProgress && (operation.isEmpty || session.writeCompleted) {
      sessions[sessionID] = nil
    }
  }
}

final class ShelfFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
  let lifecycleID = UUID()
  private let itemID: UUID
  private let fileName: String
  private let exporter: any ShelfFilePromiseExporting
  private weak var lifecycle: FilePromiseDragLifecycle?

  @MainActor
  init(
    itemID: UUID,
    fileName: String,
    exporter: any ShelfFilePromiseExporting,
    lifecycle: FilePromiseDragLifecycle? = nil
  ) {
    self.itemID = itemID
    self.fileName = fileName
    self.exporter = exporter
    self.lifecycle = lifecycle
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
      lifecycle?.promiseWriteBegan(sessionID: lifecycleID)
      defer { lifecycle?.promiseWriteEnded(sessionID: lifecycleID) }
      do {
        _ = try await exporter.export(itemID: itemID, to: url, fileName: fileName)
        completionHandler(nil)
      } catch {
        completionHandler(error)
      }
    }
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
    private let lifecycle = FilePromiseDragLifecycle()
    private var lifecycleIDs: [ObjectIdentifier: UUID] = [:]

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
        lifecycle: lifecycle
      )
      lifecycle.begin(delegate: delegate)
      let provider = NSFilePromiseProvider(fileType: fileType, delegate: delegate)
      let draggingItem = NSDraggingItem(pasteboardWriter: provider)
      let image = NSWorkspace.shared.icon(for: UTType(fileType) ?? .data)
      let origin = recognizer.location(in: view)
      draggingItem.setDraggingFrame(
        NSRect(x: origin.x - 24, y: origin.y - 24, width: 48, height: 48),
        contents: image
      )
      let session = view.beginDraggingSession(with: [draggingItem], event: event, source: self)
      lifecycleIDs[ObjectIdentifier(session)] = delegate.lifecycleID
    }

    nonisolated func draggingSession(
      _ session: NSDraggingSession,
      sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
      context == .outsideApplication ? .copy : []
    }

    nonisolated func draggingSession(
      _ session: NSDraggingSession,
      endedAt screenPoint: NSPoint,
      operation: NSDragOperation
    ) {
      Task { @MainActor [weak self] in
        guard let self,
              let sessionID = lifecycleIDs.removeValue(forKey: ObjectIdentifier(session)) else {
          return
        }
        lifecycle.draggingSessionEnded(sessionID: sessionID, operation: operation)
      }
    }
  }
}
