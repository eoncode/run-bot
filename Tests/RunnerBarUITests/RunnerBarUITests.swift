// RunnerBarUITests.swift
// RunnerBarUITests
//
// UI tests for RunnerBar using real mouse interaction.
// Runs on the self-hosted runner via xcodebuild.
//
// Design:
//   • AppDelegate calls setActivationPolicy(.regular) + activate() when
//     UI_TESTING is set, so the app runs as a normal foreground app.
//   • The status item can be clicked normally to open the panel.
//
// ⚠️ XCUIApplication must be initialised with the bundle ID (not default init)
//    to avoid Xcode 26 path resolution bug.
// ⚠️ Do NOT set XCTTargetAppPath in project.yml scheme env — Xcode 26 strips
//    the .app extension, causing a fatal "bundle ID couldn't be read" error.
//
// ⚠️ app.windows does NOT enumerate NSPanel with [.borderless, .nonactivatingPanel].
//    Borderless non-activating panels appear under app.otherElements, not app.windows.
//    ❌ NEVER use app.windows to find the RunnerBar panel.
//    ✓ Use app.staticTexts / app.buttons to verify panel content directly.
//
// ⚠️ NSPanel is non-activating — after statusItem.click() the panel is visible
//    but the app is NOT frontmost. All subsequent XCUIElement.click() calls
//    resolve coordinates relative to screen origin (0,0) and land outside.
//    FIX: call app.activate() immediately after opening the panel so macOS
//    treats it as the key app and AX coordinate resolution works correctly.
//
// ⚠️ The Settings gear button and the Settings back button both have AX label
//    "Settings" — they are never on-screen simultaneously so app.buttons["Settings"]
//    is unambiguous in each test.
//
// ⚠️ Text("Settings") in the SettingsView header is nested inside a Button —
//    it does NOT appear as a standalone staticText in the AX tree.
//    ❌ NEVER assert app.staticTexts["Settings"] to verify Settings is open.
//    ✓ Use app.staticTexts["Active local runners"] — first unconditional section header.
//
// ⚠️ The panel resizes when switching main ↔ Settings. element.click() uses a
//    cached AX snapshot and can send the click to the pre-resize coordinates,
//    landing outside the smaller window.
//    FIX: tapByCoordinate() calls coordinate(withNormalizedOffset: .center) which
//    forces a live AX re-query at the moment of the click, always using the
//    current window frame. This is documented behaviour in XCUICoordinate:
//    "Coordinates are dynamic … and may compute different screen locations at
//    different times." (developer.apple.com/documentation/xcuiautomation/xcuicoordinate)

import XCTest

final class RunnerBarUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.eonist.runnerbar")
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Opens the panel via the status item and activates the app so that
    /// all subsequent AX coordinate resolution works inside the panel.
    private func openPanel() {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 3))
        statusItem.click()
        // NSPanel is non-activating — activate() forces macOS to resolve
        // AX element coordinates relative to the panel, not screen origin.
        app.activate()
        XCTAssertTrue(
            app.staticTexts["WORKFLOWS"].waitForExistence(timeout: 5),
            "Main panel must show WORKFLOWS section header after opening"
        )
    }

    /// Taps a button using a live-resolved coordinate rather than the cached
    /// AX snapshot used by element.click().
    ///
    /// XCUICoordinate.coordinate(withNormalizedOffset:) is documented as dynamic:
    /// it re-queries the element's screen frame at the moment of the tap.
    /// This prevents clicks landing at stale coordinates when the panel has
    /// just resized (e.g. main view ↔ Settings view transition).
    ///
    /// Strategy:
    ///   1. Wait for the element to exist in the AX tree.
    ///   2. Wait for isHittable == true (layout pass complete, element on screen).
    ///   3. Log the resolved frame for diagnostics.
    ///   4. Tap via coordinate(withNormalizedOffset: .center) — live re-query.
    private func tapByCoordinate(_ element: XCUIElement, timeout: TimeInterval = 5) {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Element '\(element.label)' must exist before tapping"
        )
        let hittableExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: element
        )
        let hittableResult = XCTWaiter.wait(for: [hittableExpectation], timeout: timeout)
        XCTAssertEqual(hittableResult, .completed,
                       "Element '\(element.label)' must be hittable. Frame: \(element.frame)")
        // Log the live frame so we can diagnose any future misses.
        print("[UITest] tapping '\(element.label)' at frame \(element.frame) isHittable=\(element.isHittable)")
        // Use coordinate(withNormalizedOffset:) — dynamic, re-queries AX at tap time.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    // MARK: - Panel open

    func testPanelOpensAndShowsWorkflowsSection() {
        openPanel()
        XCTAssertTrue(
            app.staticTexts["WORKFLOWS"].waitForExistence(timeout: 5),
            "Panel should contain the 'WORKFLOWS' section header"
        )
    }

    // MARK: - Settings navigation

    /// Full settings flow:
    /// open panel → open settings → verify all section headers →
    /// Add Runner sheet (verify + cancel) → Add Scope sheet (verify + cancel) →
    /// back to main → confirm WORKFLOWS visible, Settings gone.
    func testSettingsNavigationFlow() {
        openPanel()

        // ── 1. Open Settings ──────────────────────────────────────────
        // Panel will shrink after this click — tapByCoordinate re-queries
        // the live AX frame at tap time, so coordinates are never stale.
        tapByCoordinate(app.buttons["Settings"])

        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 5),
                      "Local runners section header must appear in Settings")
        XCTAssertTrue(app.staticTexts["Remote runner scopes"].exists, "Remote scopes header")
        XCTAssertTrue(app.staticTexts["Notifications"].exists, "Notifications header")
        XCTAssertTrue(app.staticTexts["General"].exists, "General header")
        XCTAssertTrue(app.staticTexts["Account"].exists, "Account header")
        XCTAssertTrue(app.staticTexts["About"].exists, "About header")

        // ── 2. Add Runner sheet ───────────────────────────────────────
        tapByCoordinate(app.buttons["Add a new runner"])
        XCTAssertTrue(app.staticTexts["Add runner"].waitForExistence(timeout: 3),
                      "Add Runner sheet title")
        XCTAssertTrue(app.buttons["Add new"].exists)
        XCTAssertTrue(app.buttons["Add pre-existing"].exists)
        tapByCoordinate(app.buttons["Cancel"])
        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 3),
                      "Back in Settings after cancelling Add Runner")

        // ── 3. Add Scope sheet ────────────────────────────────────────
        tapByCoordinate(app.buttons["Add a remote scope"])
        XCTAssertTrue(app.staticTexts["Add remote scope"].waitForExistence(timeout: 3),
                      "Add Scope sheet title")
        XCTAssertTrue(app.buttons["Organisation"].exists)
        XCTAssertTrue(app.buttons["Repository"].exists)
        tapByCoordinate(app.buttons["Cancel"])
        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 3),
                      "Back in Settings after cancelling Add Scope")

        // ── 4. Back to main ───────────────────────────────────────────
        // Panel will expand back — tapByCoordinate re-queries live frame.
        tapByCoordinate(app.buttons["Settings"])
        XCTAssertTrue(
            app.staticTexts["WORKFLOWS"].waitForExistence(timeout: 5),
            "WORKFLOWS must reappear after navigating back to main"
        )
        XCTAssertFalse(
            app.staticTexts["Active local runners"].exists,
            "Settings content must not be visible after going back to main"
        )
    }
}
