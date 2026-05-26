// RunnerBarUITests.swift
// RunnerBarUITests
//
// ─── Architecture notes ───────────────────────────────────────────────────────
//
// Navigation model: AppDelegate.navigate(to:) replaces NSHostingController.rootView
// entirely. There is NO SwiftUI NavigationStack — each screen is a fresh root.
// The AX tree is rebuilt from scratch on every navigate() call.
//
// Coordinate space: The panel uses [.borderless, .nonactivatingPanel] + .floating
// (in UI_TESTING mode). .click() on an AX element fires a CGEvent at the element's
// HIServices screen frame centre. Because the panel IS floating (not .popUpMenu)
// and UI_TESTING activates the app as .regular, coordinates resolve correctly.
// ❌ NEVER add app.activate() between taps — it dismisses the panel.
//
// AX identifiers: SF Symbol buttons auto-label as the symbol name ("Add", "Refresh").
// ❌ NEVER query by .help() tooltip text — .help() is not an AX identifier.
// ✓ Query by .accessibilityIdentifier() — set explicitly in SettingsView.
//   addRunnerButton  → the + button next to "Active local runners"
//   addScopeButton   → the + button next to "Remote runner scopes"
//
// Build cache: always run `rm -rf .derived` before a clean test run.
// A stale build ignores source changes and reports old AX identifiers.
//
// ─────────────────────────────────────────────────────────────────────────────

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

    /// Returns a diagnostic string of ALL buttons currently in the AX tree.
    /// Embedded in every XCTAssert failure message so the exact live state
    /// is always visible without needing a second run with added logging.
    private func dumpButtons() -> String {
        let btns = app.buttons.allElementsBoundByIndex
        guard !btns.isEmpty else { return "<no buttons in AX tree>" }
        return btns.enumerated().map { idx, b in
            "  [\(idx)] id='\(b.identifier)' label='\(b.label)' frame=\(b.frame)"
        }.joined(separator: "\n")
    }

    /// Waits for existence then taps via normalised-offset coordinate.
    /// Normalised-offset clicks are relative to the element's own bounds,
    /// so they work correctly regardless of window level or coordinate space.
    /// The `label` parameter is used only for log/failure messages.
    private func tap(_ element: XCUIElement, timeout: TimeInterval = 5, label: String? = nil) {
        let desc = label ?? (element.identifier.isEmpty ? element.label : element.identifier)
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "[UITest] MISSING '\(desc)'\nAX buttons:\n\(dumpButtons())"
        )
        print("[UITest] tapping '\(desc)' frame=\(element.frame) id='\(element.identifier)'")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    /// Opens the panel via the status item and waits for the WORKFLOWS header.
    private func openPanel() {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 3), "StatusItem must exist")
        statusItem.click()
        XCTAssertTrue(
            app.staticTexts["WORKFLOWS"].waitForExistence(timeout: 5),
            "Main panel must show WORKFLOWS header\nAX buttons:\n\(dumpButtons())"
        )
    }

    // MARK: - Tests

    func testAppLaunchesWithoutCrashing() {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    func testStatusBarItemExists() {
        XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 3))
    }

    func testPanelOpensAndShowsWorkflowsSection() {
        openPanel()
        XCTAssertTrue(app.staticTexts["WORKFLOWS"].exists)
    }

    func testPanelShowsEmptyStateWhenNoWorkflows() {
        openPanel()
        let hasRows = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'running' OR label CONTAINS 'offline'")
        ).firstMatch.exists
        let hasEmpty = app.staticTexts["No recent workflows"].exists
        XCTAssertTrue(hasRows || hasEmpty, "Panel must show workflow rows or empty state")
    }

    func testPanelClosesAndReopensOnStatusItemClick() {
        openPanel()
        app.statusItems.firstMatch.click()
        Thread.sleep(forTimeInterval: 0.5)
        app.statusItems.firstMatch.click()
        XCTAssertTrue(app.staticTexts["WORKFLOWS"].waitForExistence(timeout: 5))
    }

    func testSettingsButtonExistsInHeader() {
        openPanel()
        XCTAssertTrue(
            app.buttons["Settings"].waitForExistence(timeout: 5),
            "Settings gear button (id='gearshape') must be visible"
        )
    }

    /// Full settings navigation flow:
    ///   open panel → open settings → verify all 6 section headers
    ///   → open Add Runner sheet (verify + cancel)
    ///   → open Add Scope sheet (verify + cancel)
    ///   → back to main → verify WORKFLOWS reappears
    func testSettingsNavigationFlow() {
        openPanel()

        // ── 1. Open Settings ──────────────────────────────────────────────────
        // Gear button: identifier='gearshape', label='Settings'.
        // Querying by label is unambiguous here — main view has no back button.
        tap(app.buttons["Settings"], label: "Settings gear")

        // navigate(to: settingsView()) replaces the root — new AX tree.
        // Proof of arrival: first unconditional section header in SettingsView.
        // ❌ Text("Settings") is INSIDE the back Button — never a standalone staticText.
        XCTAssertTrue(
            app.staticTexts["Active local runners"].waitForExistence(timeout: 5),
            "Settings 'Active local runners' header\nAX buttons:\n\(dumpButtons())"
        )
        XCTAssertTrue(app.staticTexts["Remote runner scopes"].exists, "Remote scopes header")
        XCTAssertTrue(app.staticTexts["Notifications"].exists, "Notifications header")
        XCTAssertTrue(app.staticTexts["General"].exists, "General header")
        XCTAssertTrue(app.staticTexts["Account"].exists, "Account header")
        XCTAssertTrue(app.staticTexts["About"].exists, "About header")

        // ── 2. Add Runner sheet ───────────────────────────────────────────────
        // .accessibilityIdentifier("addRunnerButton") is set in SettingsView.swift
        // on the + button next to "Active local runners".
        // ❌ DO NOT query by label "Add" or help "Add a new runner" — neither is the AX id.
        let addRunnerBtn = app.buttons.matching(identifier: "addRunnerButton").firstMatch
        tap(addRunnerBtn, label: "addRunnerButton (+runner)")

        XCTAssertTrue(
            app.staticTexts["Add runner"].waitForExistence(timeout: 3),
            "Add Runner sheet title\nAX buttons:\n\(dumpButtons())"
        )
        XCTAssertTrue(app.buttons["Add new"].exists, "'Add new' segment button")
        XCTAssertTrue(app.buttons["Add pre-existing"].exists, "'Add pre-existing' segment button")

        tap(app.buttons["Cancel"].firstMatch, label: "Cancel (runner sheet)")
        XCTAssertTrue(
            app.staticTexts["Active local runners"].waitForExistence(timeout: 3),
            "Must return to Settings after cancelling Add Runner sheet"
        )

        // ── 3. Add Scope sheet ───────────────────────────────────────────────
        // .accessibilityIdentifier("addScopeButton") is set in SettingsView.swift
        // on the + button next to "Remote runner scopes".
        let addScopeBtn = app.buttons.matching(identifier: "addScopeButton").firstMatch
        tap(addScopeBtn, label: "addScopeButton (+scope)")

        XCTAssertTrue(
            app.staticTexts["Add remote scope"].waitForExistence(timeout: 3),
            "Add Scope sheet title\nAX buttons:\n\(dumpButtons())"
        )
        XCTAssertTrue(app.buttons["Organisation"].exists, "'Organisation' segment button")
        XCTAssertTrue(app.buttons["Repository"].exists, "'Repository' segment button")

        tap(app.buttons["Cancel"].firstMatch, label: "Cancel (scope sheet)")
        XCTAssertTrue(
            app.staticTexts["Active local runners"].waitForExistence(timeout: 3),
            "Must return to Settings after cancelling Add Scope sheet"
        )

        // ── 4. Back to main ──────────────────────────────────────────────────
        // Back button in SettingsView: chevron.left + Text("Settings").
        // Label is "Settings". Gear is gone from this screen — unambiguous.
        tap(app.buttons["Settings"], label: "Settings back")
        XCTAssertTrue(
            app.staticTexts["WORKFLOWS"].waitForExistence(timeout: 5),
            "WORKFLOWS must reappear after back navigation\nAX buttons:\n\(dumpButtons())"
        )
        XCTAssertFalse(
            app.staticTexts["Active local runners"].exists,
            "Settings content must not be visible on main panel"
        )
    }
}
