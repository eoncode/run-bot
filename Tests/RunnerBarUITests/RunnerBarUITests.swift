// RunnerBarUITests.swift
// RunnerBarUITests
//
// UI tests for RunnerBar using real mouse interaction.
// Runs on the self-hosted runner via xcodebuild.
//
// Design:
//   • AppDelegate sets .regular activation policy + activate() when UI_TESTING is set.
//
// ⚠️ app.windows does NOT enumerate NSPanel with [.borderless, .nonactivatingPanel].
//    ❌ NEVER use app.windows. Use app.staticTexts / app.buttons directly.
//
// ⚠️ Text("Settings") is nested inside a Button — NOT a standalone staticText.
//    ❌ NEVER assert app.staticTexts["Settings"].
//    ✓ Use app.staticTexts["Active local runners"] as proof Settings is open.
//
// ⚠️ isHittable is always false for buttons inside .nonactivatingPanel.
//    ❌ NEVER wait for isHittable.
//
// ⚠️ .click() on panel elements misfires due to Quartz/HIServices Y-axis flip.
//    ❌ NEVER call .click() directly.
//    ✓ Always use .coordinate(withNormalizedOffset: CGVector(dx:0.5, dy:0.5)).click()
//
// ⚠️ AddMode Picker segments ("Add new", "Add pre-existing") and ScopeType
//    Picker segments ("Organisation", "Repository") are NOT AX buttons.
//    They render as radioButton children inside a radioGroup.
//    ❌ NEVER assert app.buttons["Add new"] etc.
//    ✓ Assert staticTexts["Add runner"] / staticTexts["Add remote scope"] as arrival proof.
//
// ⚠️ Add-runner and Add-scope buttons may have either:
//      identifier="plus"           (local build)
//      identifier="addRunnerButton" / "addScopeButton"  (remote/PR-merge build)
//    Always probe both and use whichever exists.
//    ❌ NEVER hard-code only one identifier.
//
// ⚠️ A stale RunnerBar process (launched without UI_TESTING=1) will block
//    app.launch() from re-launching the app fresh, causing setUp to time-out
//    waiting for .runningForeground. Always terminate any existing instance
//    before calling app.launch().
//
// ⚠️ ScopeEditSheet (#992): sheet is presented modally from SettingsView.
//    Arrival proof: app.staticTexts["Edit Scope"].exists
//    The sheet root carries accessibilityIdentifier "scopeEditSheet".
//    Skip gracefully (XCTSkip) when no scope rows are present in the test env.

import XCTest

final class RunnerBarUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        // Kill any stale RunnerBar process that may be running without
        // UI_TESTING=1. If we don't do this, app.launch() re-activates the
        // existing instance (which lacks the env var) and the app never
        // reaches .runningForeground from XCTest's perspective.
        let stale = XCUIApplication(bundleIdentifier: "dev.eonist.runnerbar")
        if stale.state != .notRunning {
            print("[UITest] setUp: terminating stale RunnerBar (state=\(stale.state.rawValue))")
            stale.terminate()
            // Brief pause to let the process fully exit before re-launching.
            Thread.sleep(forTimeInterval: 0.5)
        }

        app = XCUIApplication(bundleIdentifier: "dev.eonist.runnerbar")
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        let launched = app.wait(for: .runningForeground, timeout: 10)
        if !launched {
            print("[UITest] setUp: app state after wait = \(app.state.rawValue)")
            print("[UITest] setUp: AX hierarchy dump:")
            print(app.debugDescription)
        }
        XCTAssertTrue(launched, "RunnerBar must reach runningForeground within 10s")
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Opens the panel and waits for the WORKFLOWS header.
    private func openPanel() {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "Status item must exist")
        statusItem.click()
        XCTAssertTrue(
            app.staticTexts["WORKFLOWS"].waitForExistence(timeout: 5),
            "Main panel must show WORKFLOWS after status item click"
        )
    }

    /// Waits for existence, then clicks centre via normalised-offset coordinate.
    /// Avoids the Quartz/HIServices Y-axis flip that direct .click() suffers on
    /// borderless nonActivatingPanels.
    private func tapButton(_ element: XCUIElement, timeout: TimeInterval = 5) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Element must exist: \(element.debugDescription)")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    /// Returns the Add-Runner button, probing the stable explicit identifier first
    /// and falling back to the legacy 'plus' + index approach.
    ///
    /// Local builds expose identifier="plus" (boundBy:0 = Add Runner).
    /// Remote/PR-merge builds expose identifier="addRunnerButton".
    /// We probe both so the test is environment-agnostic.
    private func addRunnerButton() -> XCUIElement {
        let explicit = app.buttons["addRunnerButton"]
        if explicit.waitForExistence(timeout: 0.5) {
            print("[UITest] addRunnerButton: found via identifier='addRunnerButton'")
            return explicit
        }
        let fallback = app.buttons.matching(identifier: "plus").element(boundBy: 0)
        print("[UITest] addRunnerButton: falling back to identifier='plus' boundBy:0")
        return fallback
    }

    /// Returns the Add-Scope button, probing the stable explicit identifier first
    /// and falling back to the legacy 'plus' + index approach.
    ///
    /// Local builds expose identifier="plus" (boundBy:1 = Add Scope).
    /// Remote/PR-merge builds expose identifier="addScopeButton".
    private func addScopeButton() -> XCUIElement {
        let explicit = app.buttons["addScopeButton"]
        if explicit.waitForExistence(timeout: 0.5) {
            print("[UITest] addScopeButton: found via identifier='addScopeButton'")
            return explicit
        }
        let fallback = app.buttons.matching(identifier: "plus").element(boundBy: 1)
        print("[UITest] addScopeButton: falling back to identifier='plus' boundBy:1")
        return fallback
    }

    // MARK: - Settings navigation

    /// Full settings flow:
    /// open panel → Settings → verify sections →
    /// Add Runner sheet (open + cancel) →
    /// Add Scope sheet (open + cancel) →
    /// back to main.
    func testSettingsNavigationFlow() {
        openPanel()

        // ── 1. Open Settings ──────────────────────────────────────────
        tapButton(app.buttons["Settings"])
        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 5),
                      "Active local runners section")
        XCTAssertTrue(app.staticTexts["Remote runner scopes"].exists, "Remote runner scopes")
        XCTAssertTrue(app.staticTexts["Notifications"].exists, "Notifications")
        XCTAssertTrue(app.staticTexts["General"].exists, "General")
        XCTAssertTrue(app.staticTexts["Account"].exists, "Account")
        XCTAssertTrue(app.staticTexts["About"].exists, "About")

        // ── 2. Add Runner sheet ───────────────────────────────────────
        tapButton(addRunnerButton())
        XCTAssertTrue(app.staticTexts["Add runner"].waitForExistence(timeout: 3),
                      "Add Runner sheet title")
        tapButton(app.buttons["Cancel"])
        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 3),
                      "Back in Settings after Cancel")

        // ── 3. Add Scope sheet ────────────────────────────────────────
        tapButton(addScopeButton())
        XCTAssertTrue(app.staticTexts["Add remote scope"].waitForExistence(timeout: 3),
                      "Add Scope sheet title")
        tapButton(app.buttons["Cancel"])
        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 3),
                      "Back in Settings after Cancel")

        // ── 4. Back to main ───────────────────────────────────────────
        tapButton(app.buttons["Settings"])
        XCTAssertTrue(
            app.staticTexts["WORKFLOWS"].waitForExistence(timeout: 5),
            "WORKFLOWS must reappear after back navigation"
        )
        XCTAssertFalse(
            app.staticTexts["Active local runners"].exists,
            "Settings content must not be visible on main view"
        )
    }

    // MARK: - ScopeEditSheet (#992)

    /// Verifies that tapping a scope row opens ScopeEditSheet as a modal sheet,
    /// that Cancel dismisses it back to Settings, and that Save also dismisses it.
    ///
    /// Skips gracefully when no scope rows exist in the test environment
    /// (CI runners have no pre-seeded scopes).
    func testScopeEditSheetFlow() throws {
        openPanel()
        tapButton(app.buttons["Settings"])
        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 5),
                      "Must reach Settings")

        // Scope rows have no stable identifier — they are plain Button rows whose
        // first child is the Repo/Org type badge. We detect presence via the
        // "Edit Scope" title that appears once a row is tapped. If no rows exist
        // we skip rather than fail so CI stays green on fresh installs.
        let firstScopeRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Repo' OR label CONTAINS 'Org'")).firstMatch
        guard firstScopeRow.waitForExistence(timeout: 2) else {
            print("[UITest] testScopeEditSheetFlow: no scope rows found — skipping")
            throw XCTSkip("No scope rows present in test environment")
        }

        // ── 1. Open ScopeEditSheet ────────────────────────────────────
        tapButton(firstScopeRow)
        XCTAssertTrue(app.staticTexts["Edit Scope"].waitForExistence(timeout: 3),
                      "ScopeEditSheet must show 'Edit Scope' title")
        XCTAssertTrue(app.staticTexts["Scope Info"].exists, "Scope Info section must be visible")
        XCTAssertTrue(app.staticTexts["Monitoring"].exists, "Monitoring section must be visible")

        // ── 2. Cancel dismisses sheet ─────────────────────────────────
        tapButton(app.buttons["Cancel"])
        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 3),
                      "Settings must reappear after Cancel")
        XCTAssertFalse(app.staticTexts["Edit Scope"].exists,
                       "ScopeEditSheet must not be visible after Cancel")

        // ── 3. Save dismisses sheet ───────────────────────────────────
        tapButton(firstScopeRow)
        XCTAssertTrue(app.staticTexts["Edit Scope"].waitForExistence(timeout: 3),
                      "ScopeEditSheet must reopen")
        tapButton(app.buttons["Save"])
        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 3),
                      "Settings must reappear after Save")
        XCTAssertFalse(app.staticTexts["Edit Scope"].exists,
                       "ScopeEditSheet must not be visible after Save")
    }
}
