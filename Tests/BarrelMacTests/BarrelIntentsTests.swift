import XCTest
@testable import BarrelMac

final class BarrelIntentsTests: XCTestCase {
  func testShowShelfIntentDoesNotRequestAppActivation() {
    XCTAssertFalse(ShowShelfIntent.openAppWhenRun)
  }

  @MainActor
  func testShowShelfIntentPostsShowShelfNotification() async throws {
    let notification = expectation(forNotification: .showBarrelShelf, object: nil)

    _ = try await ShowShelfIntent().perform()

    await fulfillment(of: [notification], timeout: 1)
  }
}
