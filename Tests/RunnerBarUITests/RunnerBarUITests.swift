// RunnerBarUITests.swift
// RunnerBarUITests
import XCTest

// ⚠️ runner-bar uses NSPanel, NOT NSPopover.
// ❌ NEVER query app.popovers — always use app.windows.
// The app is LSUIElement=YES: no Dock icon, no app switcher, no visible windows.
final class RunnerBarUITests: XCTestCase {

    var app: XCUIApplication!

    // macOS 13+ routes status bar items through Control Centre, not systemuiserver.
    // ❌ NEVER use "com.apple.systemuiserver" — it will not find the status item on modern macOS.
    private let controlCentre = XCUIApplication(bundleIdentifier: "com.apple.controlcenter")

    // The stable accessibility identifier set on the NSStatusItem button in AppDelegate+StatusItem.swift.
    // ❌ NEVER use controlCentre.statusItems["RunnerBarStatusItem"] — the subscript matches by
    //    accessibility label/title, NOT by the programmatic identifier. On macOS 26 the button has
    //    no text label (it's an SF Symbol image), so the subscript always resolves to a missing element.
    // ❌ NEVER use controlCentre.statusItems["com.eoncode.runner-bar"] — bundle ID lookup is broken on macOS 26.
    // ❌ NEVER use controlCentre.statusItems.firstMatch — resolves to com.apple.menuextra.battery on macOS 26.
    private var statusItem: XCUIElement {
        controlCentre.descendants(matching: .statusItem)
            .matching(NSPredicate(format: "identifier == 'RunnerBarStatusItem'"))
            .firstMatch
    }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // ⚠️ --uitesting bypasses Keychain reads and API polling.
        // Without this the test run will silently hang waiting for a
        // Keychain approval prompt that never comes in CI.
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    // MARK: - Smoke tests

    func testAppLaunchesWithoutCrashing() {
        // LSUIElement app never enters runningForeground — runningBackground is the correct state.
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
    }

    func testStatusBarItemExists() {
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
    }

    func testPanelOpensOnClick() {
        // NSPanel — query app.windows, NOT app.popovers.
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 3))
    }

    func testPanelDismissesOnSecondClick() {
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 3))
        statusItem.click()
        // 4s gives the panel enough time to fully dismiss under CI load
        XCTAssertFalse(app.windows.firstMatch.waitForExistence(timeout: 4))
    }
}
