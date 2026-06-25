// NavState.swift
// RunnerBar
import RunnerBarCore

// MARK: - NavState
//
// ❌ DO NOT MOVE TO RunnerBarCore.
//
// Although this file imports only RunnerBarCore (no AppKit/SwiftUI import line),
// NavState is a UI router enum — its cases map directly onto NSPopover/NSPanel
// screens and its sole consumer is AppDelegate + AppDelegate+Navigation, which
// uses it as the input to `validatedView(for:) -> AnyView?` (a SwiftUI view
// factory). There is no domain logic here worth testing with `swift test`
// headlessly, and Core has no business defining navigation states that are
// meaningful only in the context of an AppKit status-bar popover.
//
// History:
// #455: Removed .jobDetail, .actionDetail, .actionJobDetail, .actionStepLog.
// Navigation from the main view now goes directly: inline step tap → .stepLog.
// #992: Removed .scopeDetail — ScopeEditSheet is now a modal sheet presented
// directly from SettingsView, not a nav drill-down.
// #1001: Removed .runnerDetail — runner editing is now a popover in SettingsView.

/// Represents the currently visible navigation screen inside the RunnerBar panel.
///
/// Extracted from AppDelegate.swift (#602) — was a private enum co-located with
/// AppDelegate. Moved here so navigation cases can be extended without opening
/// AppDelegate.
///
/// - Important: Intentionally kept in the `RunnerBar` app target. The clean
///   import list is misleading — this is a UI navigation type consumed entirely
///   by AppKit/SwiftUI app-layer code. See file-level comment for rationale.
enum NavState {
    /// The root popover showing runners and the recent-actions list.
    case main
    /// The raw log for a single step, reached from the main inline step row.
    /// - Parameters:
    ///   - job: The active job providing context for the selected step.
    ///   - step: The specific step whose log is displayed.
    case stepLog(job: ActiveJob, step: JobStep)
    /// The Settings sheet.
    case settings
}
