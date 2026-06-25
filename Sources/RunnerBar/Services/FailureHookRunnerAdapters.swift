// FailureHookRunnerAdapters.swift
// RunnerBar
//
// Production adapters that bridge dependencies to the protocols expected by
// `FailureHookRunnerUseCase`.
import Foundation
import RunnerBarCore

// MARK: - DefaultTerminalLauncher

/// Forwards `open(_:)` to `TerminalLauncher.open(command:)`.
/// Used as the production dependency for `FailureHookRunnerUseCase`.
///
/// # Why this lives in the app target
/// `DefaultTerminalLauncher` is the concrete production conformance to
/// `TerminalLauncherProtocol` (defined in `RunnerBarCore`). It depends on
/// `TerminalLauncher.open()` which uses `NSAppleScript` — an AppKit-bound,
/// macOS-only API that requires a running user session. Keeping the protocol
/// in Core and the concrete adapter here follows the same pattern used
/// throughout the codebase for AppKit-bound dependencies.
///
/// `@MainActor` is required because `NSAppleScript` (used inside
/// `TerminalLauncher.open`) must run on the main thread. (#1538)
struct DefaultTerminalLauncher: TerminalLauncherProtocol {
    /// Forwards to `TerminalLauncher.open(command:)`. Must be called on `@MainActor`.
    @MainActor
    func open(_ command: String) {
        TerminalLauncher.open(command: command)
    }
}
