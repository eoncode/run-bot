import XCTest

final class RunnerBarUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.eoncode.runner-bar")
        app.launch()
        // Allow time for the status item to register in the menu bar
        Thread.sleep(forTimeInterval: 1.5)
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - Helpers

    /// Finds the RunnerBar status item by its accessibility identifier.
    /// Status items live in the controlcenter process on macOS 13+.
    private var runnerBarStatusItem: XCUIElement {
        let predicate = NSPredicate(format: "identifier == 'RunnerBarStatusItem'")
        // Try our own app process first (works when launched by xcodebuild)
        let ownItem = app.statusItems.matching(predicate).firstMatch
        if ownItem.exists { return ownItem }
        // Fall back: status items are parented by controlcenter
        return XCUIApplication(bundleIdentifier: "com.apple.controlcenter")
            .statusItems.matching(predicate).firstMatch
    }

    // MARK: - Tests

    func testAppLaunchesWithoutCrashing() throws {
        XCTAssertTrue(
            app.state == .runningForeground || app.state == .runningBackground,
            "RunnerBar should be running after launch, got state: \(app.state.rawValue)"
        )
    }

    func testStatusBarItemExists() throws {
        XCTAssertTrue(
            runnerBarStatusItem.waitForExistence(timeout: 5),
            "RunnerBar status item (identifier 'RunnerBarStatusItem') should exist in the menu bar"
        )
    }

    func testPanelOpensOnClick() throws {
        let statusItem = runnerBarStatusItem
        XCTAssertTrue(
            statusItem.waitForExistence(timeout: 5),
            "RunnerBar status item must exist before clicking"
        )
        statusItem.click()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 3),
            "A window should appear after clicking the status item"
        )
    }
}
