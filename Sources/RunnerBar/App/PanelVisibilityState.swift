// PanelVisibilityState.swift
// RunnerBar
import SwiftUI

// ════════════════════════════════════════════════════════════════════════════════
// ⚠️ PanelVisibilityState — SIDE-JUMP REGRESSION GUARD (ref #377 #375 #376)
// ════════════════════════════════════════════════════════════════════════════════
//
// PURPOSE:
// 1. Provides a live, mutable signal of whether the NSPopover is currently open.
// 2. Carries a one-shot height-ready callback used by the KVO-driven resize path.
// 3. Carries `dismissSheetsTrigger` — a toggle AppDelegate flips to ask SwiftUI
//    views to dismiss their open sheets before the popover closes.
//
// WHY NOT A PLAIN Bool PROP:
// AppDelegate constructs PanelMainView (via mainView()) BEFORE the panel
// opens. Any plain `var isPanelOpen: Bool` prop is therefore always `false`
// at the point views evaluate it. This @EnvironmentObject is mutated by
// AppDelegate immediately before show() and after close(), so the value
// seen inside the view is always live.
//
// dismissSheetsTrigger — HOW IT WORKS:
// AppKit does NOT remove child sheet NSWindows when NSPopover.performClose()
// fires. They become orphans: still attached, still intercepting all mouse
// events, but with no SwiftUI tree driving them. The app appears frozen.
//
// The fix: AppDelegate toggles dismissSheetsTrigger BEFORE performClose().
// SettingsView (and any other view with sheets) observes this toggle via
// .onChange and sets all its sheet bindings to nil/false. SwiftUI then tears
// down the sheet NSWindow through its own presentation path — no orphan.
// After one runloop tick (Task { await MainActor.run {} }) AppDelegate calls
// performClose(); by then the sheet window is gone.
//
// ❌ NEVER set dismissSheetsTrigger and performClose() in the same synchronous
//    call — SwiftUI needs one runloop tick to process the binding change.
// ❌ NEVER remove dismissSheetsTrigger from PanelVisibilityState.
// ❌ NEVER remove the .onChange(of: panelVisibilityState.dismissSheetsTrigger)
//    modifier from SettingsView (or any view that presents sheets).
//
// ════════════════════════════════════════════════════════════════════════════════

/// Observable wrapper for NSPopover open/closed state + one-shot height callback
/// + sheet-dismiss trigger.
final class PanelVisibilityState: ObservableObject {
    /// `true` from immediately before the popover opens until after it closes.
    @Published var isOpen: Bool = false

    /// Toggled by AppDelegate to signal all SwiftUI views to dismiss open sheets.
    /// Views observe this with .onChange and nil their sheet bindings.
    /// AppDelegate then calls performClose() on the next runloop tick.
    /// ❌ NEVER remove.
    @Published var dismissSheetsTrigger: Bool = false

    // periphery:ignore
    /// Set to `false` before each `show()`, set to `true` after first height report.
    var heightReported: Bool = false

    // periphery:ignore
    /// Called ONCE after the first real rendered height is known.
    var onHeightReady: ((CGFloat) -> Void)?
}
