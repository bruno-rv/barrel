import BarrelCore
import CloudKit
import Foundation

@MainActor
final class SyncController: ObservableObject {
  enum Status: Equatable {
    case disabled
    case unavailable(String)
    case syncing
    case synced(Date)
    case failed(String)
  }

  @Published private(set) var status: Status = .disabled

  let containerIdentifier = CloudKitSyncService.defaultContainerIdentifier

  private let repository: ShelfRepository
  private let container: CKContainer
  private let transport: CloudKitSyncService
  private var syncTask: Task<Void, Never>?
  private var enabled = false

  init(repository: ShelfRepository = BarrelEnvironment.shared.repository) {
    self.repository = repository
    container = CKContainer(identifier: CloudKitSyncService.defaultContainerIdentifier)
    transport = CloudKitSyncService()
  }

  var statusText: String {
    switch status {
    case .disabled: "Disabled"
    case .unavailable(let reason): "Unavailable: \(reason)"
    case .syncing: "Syncing…"
    case .synced(let date): "Last synced \(date.formatted(date: .abbreviated, time: .shortened))"
    case .failed(let message): "Failed: \(message)"
    }
  }

  var canSync: Bool {
    enabled && status != .syncing
  }

  func setEnabled(_ enabled: Bool) {
    self.enabled = enabled
    syncTask?.cancel()
    syncTask = nil
    guard enabled else {
      status = .disabled
      return
    }
    syncNow()
  }

  func syncNow() {
    guard enabled, status != .syncing else { return }
    syncTask = Task { [weak self] in
      await self?.synchronize()
    }
  }

  private func synchronize() async {
    status = .syncing
    do {
      let accountStatus = try await container.accountStatus()
      guard accountStatus == .available else {
        status = .unavailable(accountStatus.reason)
        return
      }
      let local = await repository.syncRecords()
      let merged = try await SyncCoordinator.synchronize(local: local, transport: transport)
      try Task.checkCancellation()
      try await repository.applySyncRecords(merged)
      status = .synced(.now)
      NotificationCenter.default.post(name: .repositoryDidChange, object: self)
    } catch is CancellationError {
      if !enabled { status = .disabled }
    } catch let error as CKError where error.code == .notAuthenticated || error.code == .permissionFailure {
      status = .unavailable(error.localizedDescription)
    } catch {
      status = .failed(error.localizedDescription)
    }
  }
}

private extension CKAccountStatus {
  var reason: String {
    switch self {
    case .available: "Available"
    case .couldNotDetermine: "iCloud account status could not be determined."
    case .restricted: "This iCloud account is restricted."
    case .noAccount: "No iCloud account is signed in."
    case .temporarilyUnavailable: "iCloud is temporarily unavailable."
    @unknown default: "Unknown iCloud account status."
    }
  }
}
