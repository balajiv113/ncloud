import XCTest

final class RunnerUITests: XCTestCase {
  func testGrantFullPhotoAccess() {
    continueAfterFailure = false
    let app = XCUIApplication()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let fullAccessLabels = ["Allow Full Access", "Allow Access to All Photos"]
    let monitor = addUIInterruptionMonitor(withDescription: "Photos Full Access permission") { alert in
      for label in fullAccessLabels {
        let button = alert.buttons[label]
        if button.exists && button.isHittable {
          button.tap()
          return true
        }
      }
      return false
    }
    defer {
      removeUIInterruptionMonitor(monitor)
      app.terminate()
    }

    app.launch()
    let permission = app.descendants(matching: .any)
      .matching(identifier: "ios-photos-permission").firstMatch
    guard permission.waitForExistence(timeout: 45) else {
      XCTFail("Missing integration fixture button ios-photos-permission. Build integration_test/mobile_test.dart, not production main.dart.\n\(app.debugDescription)")
      return
    }
    guard permission.isHittable else {
      XCTFail("Integration Photos permission button is not hittable.\n\(app.debugDescription)")
      return
    }
    permission.tap()

    let ready = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@", "Photos access ready")).firstMatch
    let failed = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Photos access failed:")).firstMatch
    let deadline = Date().addingTimeInterval(60)
    var stimulatedInterruption = false
    while Date() < deadline {
      if ready.waitForExistence(timeout: 1) { return }
      if failed.exists {
        XCTFail("The integration fixture rejected Photos access: \(failed.label)\nApp alerts: \(app.alerts.debugDescription)\nSpringBoard alerts: \(springboard.alerts.debugDescription)")
        return
      }
      // Some iOS versions expose privacy alerts to SpringBoard rather than the
      // application. Never choose Limited Access, Select Photos, or a generic Allow.
      var approved = false
      for owner in [springboard, app] {
        for label in fullAccessLabels {
          let button = owner.alerts.buttons[label].firstMatch
          if button.exists && button.isHittable {
            button.tap()
            approved = true
            break
          }
        }
        if approved { break }
      }
      if !approved && !stimulatedInterruption {
        // Interruption monitors run in response to a subsequent app interaction.
        // A system alert consumes this tap; there is no second permission request.
        stimulatedInterruption = true
        app.tap()
      }
    }
    XCTFail("""
      Photos Full Access did not complete within 60 seconds. Only Full Access is accepted.
      App state: \(app.state.rawValue)
      App alerts: \(app.alerts.debugDescription)
      SpringBoard alerts: \(springboard.alerts.debugDescription)
      App hierarchy: \(app.debugDescription)
      """)
  }
}
