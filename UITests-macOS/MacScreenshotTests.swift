import AppKit
import XCTest

/// The macOS half of the screenshot pipeline. fastlane's `snapshot` is
/// iOS/tvOS only, so this does the same job with plain XCUITest: launch with
/// the shared fixtures, capture the window, and composite it onto a canvas at
/// one of the sizes App Store Connect accepts.
///
/// Determinism matches the iOS side - fixtures through the argument domain,
/// no sleep timer running, menu captured last. The extra macOS concern is the
/// window frame, which AppKit would otherwise restore from the previous run,
/// so the test pins it before capturing.
final class MacScreenshotTests: XCTestCase {
    /// A size App Store Connect accepts for Mac screenshots.
    private static let canvas = NSSize(width: 2880, height: 1800)

    /// AppKit restores the window frame from this key, so without pinning it
    /// the capture size drifts between runs. Going through the argument
    /// domain keeps it volatile - the real preferences are untouched.
    /// Value is "x y w h screenX screenY screenW screenH".
    private static let windowFrame = [
        "-NSWindow Frame Hushaboom.ContentView-1-AppWindow-1",
        "100 100 1000 780 0 0 2560 1409 ",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments += ScreenshotFixtures.launchArguments + Self.windowFrame
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30), "window never appeared")

        XCTAssertTrue(app.staticTexts["Ocean"].waitForExistence(timeout: 10))
        capture(window, named: "01-mixer")

        app.staticTexts["Ocean"].tap()
        XCTAssertTrue(
            app.staticTexts["Period"].waitForExistence(timeout: 10),
            "ocean sub-settings never expanded"
        )
        capture(window, named: "02-sound-detail")
        app.staticTexts["Ocean"].tap()

        let sleepTimer = app.descendants(matching: .any)
            .matching(identifier: "sleepTimerMenu").firstMatch
        XCTAssertTrue(sleepTimer.waitForExistence(timeout: 10), "sleep timer menu missing")
        sleepTimer.click()
        XCTAssertTrue(
            app.menuItems["30 minutes"].waitForExistence(timeout: 10),
            "sleep timer menu never opened"
        )
        capture(window, named: "03-sleep-timer")
    }

    @MainActor
    private func capture(_ window: XCUIElement, named name: String) {
        let shot = window.screenshot().image

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(Self.canvas.width),
            pixelsHigh: Int(Self.canvas.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            XCTFail("could not allocate the canvas")
            return
        }
        rep.size = Self.canvas

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
        NSRect(origin: .zero, size: Self.canvas).fill()

        // Scale to leave a consistent margin, so the window reads as a window
        // rather than filling the frame edge to edge.
        let maxHeight = Self.canvas.height * 0.72
        let scale = min(maxHeight / shot.size.height, 1.6)
        let drawn = NSSize(width: shot.size.width * scale, height: shot.size.height * scale)
        shot.draw(in: NSRect(
            x: (Self.canvas.width - drawn.width) / 2,
            y: (Self.canvas.height - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        ))

        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("could not encode \(name)")
            return
        }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
