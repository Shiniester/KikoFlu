import Flutter
import UIKit
import XCTest
import Testing
@testable import Runner

@MainActor
@Test func screenAwakeCombinesAppAndVideoRequests() {
  let original = UIApplication.shared.isIdleTimerDisabled
  defer { UIApplication.shared.isIdleTimerDisabled = original }
  let requests = ScreenAwakeRequests()
  requests.app = true
  requests.video = true
  requests.video = false
  #expect(UIApplication.shared.isIdleTimerDisabled)
  requests.app = false
  #expect(!UIApplication.shared.isIdleTimerDisabled)
  requests.video = true
  requests.app = true
  requests.app = false
  #expect(UIApplication.shared.isIdleTimerDisabled)
  requests.video = false
  #expect(!UIApplication.shared.isIdleTimerDisabled)
}

class RunnerTests: XCTestCase {

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

}
