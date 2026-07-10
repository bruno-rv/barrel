import BarrelCore
import CloudKit
import Foundation
import Security

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
  private let defaults: UserDefaults
  private var syncTask: Task<Void, Never>?
  private var debounceTask: Task<Void, Never>?
  private var repositoryObserver: NSObjectProtocol?
  private var enabled: Bool
  private var needsSyncAfterCurrent = false

  init(
    repository: ShelfRepository = BarrelEnvironment.shared.repository,
    defaults: UserDefaults = .standard
  ) {
    self.repository = repository
    self.defaults = defaults
    enabled = defaults.bool(forKey: "CloudSyncEnabled")
    repositoryObserver = NotificationCenter.default.addObserver(
      forName: .repositoryDidChange,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      Task { @MainActor in
        guard let self, notification.object as AnyObject? !== self else { return }
        self.scheduleSync()
      }
    }
    if enabled {
      Task { [weak self] in self?.syncNow() }
    }
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

  var canSync: Bool { enabled && status != .syncing }

  func setEnabled(_ enabled: Bool) {
    self.enabled = enabled
    defaults.set(enabled, forKey: "CloudSyncEnabled")
    debounceTask?.cancel()
    debounceTask = nil
    syncTask?.cancel()
    syncTask = nil
    needsSyncAfterCurrent = false
    guard enabled else {
      status = .disabled
      return
    }
    syncNow()
  }

  func syncNow() {
    guard enabled else { return }
    guard status != .syncing else {
      needsSyncAfterCurrent = true
      return
    }
    needsSyncAfterCurrent = false
    syncTask?.cancel()
    syncTask = Task { [weak self] in
      await self?.synchronize()
    }
  }

  private func scheduleSync() {
    guard enabled else { return }
    debounceTask?.cancel()
    debounceTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(750))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self?.syncNow()
    }
  }

  private func synchronize() async {
    defer {
      syncTask = nil
      if enabled, needsSyncAfterCurrent {
        needsSyncAfterCurrent = false
        scheduleSync()
      }
    }
    status = .syncing
    if let entitlementFailureReason {
      status = .unavailable(entitlementFailureReason)
      return
    }
    let container = CKContainer(identifier: containerIdentifier)
    let transport = CloudKitSyncService(containerIdentifier: containerIdentifier)
    do {
      try Task.checkCancellation()
      let accountStatus = try await container.accountStatus()
      try Task.checkCancellation()
      guard accountStatus == .available else {
        status = .unavailable(accountStatus.reason)
        return
      }
      let local = try await repository.syncRecords()
      try Task.checkCancellation()
      let merged = try await SyncCoordinator.synchronize(local: local, transport: transport)
      try Task.checkCancellation()
      try await repository.applySyncRecords(merged)
      try Task.checkCancellation()
      await transport.removeStagedAssets()
      guard enabled else {
        status = .disabled
        return
      }
      status = .synced(.now)
      NotificationCenter.default.post(name: .repositoryDidChange, object: self)
    } catch is CancellationError {
      await transport.removeStagedAssets()
      if !enabled { status = .disabled }
    } catch let error as CKError
    where error.code == .notAuthenticated || error.code == .permissionFailure {
      await transport.removeStagedAssets()
      status = .unavailable(error.localizedDescription)
    } catch {
      await transport.removeStagedAssets()
      status = .failed(error.localizedDescription)
    }
  }

  private var entitlementFailureReason: String? {
    guard let task = SecTaskCreateFromSelf(nil) else {
      return "The app's iCloud entitlements could not be read."
    }
    let identifiers = SecTaskCopyValueForEntitlement(
      task,
      "com.apple.developer.icloud-container-identifiers" as CFString,
      nil
    ) as? [String]
    guard identifiers?.contains(containerIdentifier) == true else {
      return "The app is not signed for the \(containerIdentifier) iCloud container."
    }
    let services = SecTaskCopyValueForEntitlement(
      task,
      "com.apple.developer.icloud-services" as CFString,
      nil
    ) as? [String]
    guard services?.contains("CloudKit") == true else {
      return "The app is not signed for the CloudKit iCloud service."
    }
    return nil
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
