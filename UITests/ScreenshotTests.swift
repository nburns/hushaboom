import XCTest

/// Captures the App Store screenshots. Everything on screen has to be
/// identical run to run, or every release turns into a screenshot review.
///
/// Determinism comes from four places:
///
/// - Fixtures are injected through the argument domain (`-key value`), which
///   UserDefaults reads ahead of anything on disk. It is volatile, so a run
///   cannot leak into the next one or into a real install, and the app needs
///   no screenshot-only code path.
/// - The sleep timer is never started. Its label is `Text(_, style: .timer)`,
///   a live counter that ticks every second - the one genuinely
///   unscreenshottable thing in the UI.
/// - The menu is captured last, so dismissing it cannot land a stray tap on a
///   slider and change a value that a later screenshot depends on.
/// - The status bar is frozen by snapshot's `override_status_bar`.
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureScreenshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app)

        app.launchArguments += ScreenshotFixtures.launchArguments
        app.launch()

        let ocean = app.staticTexts["Ocean"]
        XCTAssertTrue(ocean.waitForExistence(timeout: 30), "mixer never appeared")
        snapshot("01-mixer")

        ocean.tap()
        XCTAssertTrue(
            app.staticTexts["Period"].waitForExistence(timeout: 10),
            "ocean sub-settings never expanded"
        )
        snapshot("02-sound-detail")
        ocean.tap()

        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "settings button missing")
        settings.tap()
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 10),
            "settings sheet never appeared"
        )
        snapshot("03-settings")
        app.buttons["Done"].tap()

        let sleepTimer = app.buttons["sleepTimerMenu"]
        XCTAssertTrue(sleepTimer.waitForExistence(timeout: 10), "sleep timer menu missing")
        sleepTimer.tap()
        XCTAssertTrue(
            app.buttons["30 minutes"].waitForExistence(timeout: 10),
            "sleep timer menu never opened"
        )
        snapshot("04-sleep-timer")
    }
}
