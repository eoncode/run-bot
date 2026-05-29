// PanelSheetState.swift
// RunnerBar
import Combine
import Foundation
import RunnerBarCore

// MARK: - PanelSheetState

/// Process-lifetime sheet state owned by AppDelegate, not by SettingsView.
///
/// SwiftUI may clear a `.sheet(item:)` binding when the NSPopover window is
/// hidden because the attached sheet NSWindow is removed with its parent. This
/// object keeps the user's sheet intent outside the transient SettingsView
/// state so hiding the status-bar panel can be restored on the next open.
@MainActor
final class PanelSheetState: ObservableObject {
    /// The runner currently selected for the runner detail sheet.
    @Published var editingRunner: RunnerModel?

    /// Snapshot captured immediately before a transient hide.
    private var runnerSheetSnapshot: RunnerModel?

    /// Captures the current runner sheet before hiding the popover.
    func captureTransientHideState() {
        runnerSheetSnapshot = editingRunner
    }

    /// Restores the runner sheet after the popover has been shown again.
    func restoreTransientHideStateIfNeeded() {
        guard editingRunner == nil, let runnerSheetSnapshot else { return }
        editingRunner = runnerSheetSnapshot
    }

    /// Clears all runner sheet state for explicit close/reset paths.
    func clearRunnerSheet() {
        editingRunner = nil
        runnerSheetSnapshot = nil
    }
}
