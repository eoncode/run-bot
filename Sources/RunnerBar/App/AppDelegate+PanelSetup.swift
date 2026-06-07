// AppDelegate+PanelSetup.swift
// RunnerBar
import AppKit
import Combine
import SwiftUI

// MARK: - AppDelegate + Panel Setup
//
// Owns NSPopover construction, KVO on preferredContentSize, and Combine
// subscriptions that drive icon/store updates.
// Called once from applicationDidFinishLaunching via setupPanel().
//
// ❌ NEVER inline this back into AppDelegate.swift.
// ❌ NEVER call setupPanel() more than once.
//
// WHY NSPopover (#1017):
// NSPopover uses NSPopoverWindowFrame whose chrome is drawn by the
// window-server compositor. Rounded corners survive SwiftUI .sheet
// attachment natively — no CALayer manipulation required or desired.
//
// SHEET HANDLING:
// SwiftUI .sheet() attaches as a child NSWindow to the popover's backing
// window. Two problems arise:
//
// 1. NO DIM: NSPopoverWindowFrame does not participate in AppKit's standard
//    modal sheet dimming. Fix: PanelContainerView polls NSWindow.sheets and
//    overlays Color.black.opacity(0.35) when a sheet is present.
//
// 2. OUTSIDE-TAP BEHAVIOUR DURING SHEET:
//    Desired: tapping outside while a sheet is open hides the popover
//    (so the user can interact with other apps), but saves nav state so
//    re-opening the status bar app restores the sheet context.
//
//    Implementation:
//    - popoverShouldClose always returns true. AppKit is never blocked.
//    - popoverDidClose saves hasActiveSheet into a flag before state clears.
//    - openPanel restores via savedNavState (already the case).
//    - The global event monitor no longer has a hasActiveSheet guard —
//      outside clicks always trigger closePanel().
//    - closePanel() does NOT call endSheet on any open sheet. The sheet
//      window is a child of the popover window; when the popover window
//      closes, AppKit removes all child windows including the sheet.
//      On re-open, SwiftUI re-presents the sheet if the binding is still true
//      (e.g. showAddScopeSheet = true is preserved in @State in SettingsView).
//      savedNavState = .settings ensures we navigate back to SettingsView.
//
// SIZE NOTE:
// popover.contentSize is updated (both width AND height) via KVO on
// NSHostingController.preferredContentSize. Updating contentSize resizes
// the popover in-place — the arrow stays pinned to the original
// positioningRect. ❌ NEVER call popover.show() again on resize.

/// Extension responsible for NSPopover construction, KVO, and Combine subscriptions.
extension AppDelegate: NSPopoverDelegate {

    // MARK: Popover construction

    /// Builds the NSPopover, embeds the SwiftUI hosting controller, wires KVO
    /// and Combine subscriptions.
    func setupPanel() {
        let controller = NSHostingController(rootView: mainView())
        controller.sizingOptions = .preferredContentSize
        hostingController = controller

        let newPopover = NSPopover()
        newPopover.contentViewController = controller
        newPopover.contentSize = NSSize(width: 480, height: 300)
        newPopover.animates = false
        newPopover.behavior = .applicationDefined
        newPopover.delegate = self

        popover = newPopover

        setupKVO(controller: controller)
        setupCombineSubscriptions()
    }

    // MARK: NSPopoverDelegate

    /// Always allow close. Outside-tap during a sheet hides the popover so the
    /// user can interact with other apps. Nav state is preserved and restored
    /// on next open via savedNavState.
    public func popoverShouldClose(_ _: NSPopover) -> Bool {
        return true
    }

    /// Syncs internal state after the popover closes for any reason.
    /// Primary purpose: safety net for OS-initiated closes (e.g. user clicks outside).
    /// When `closePanel()` or `hidePanel()` drives the close, they call
    /// `tearDownOpenState()` directly — by the time this fires, `panelIsOpen`
    /// is already `false` and the guard exits immediately.
    public func popoverDidClose(_ _: Notification) {
        guard panelIsOpen else { return }
        tearDownOpenState()
    }

    // MARK: KVO

    /// Observes `preferredContentSize` and updates both width and height.
    private func setupKVO(controller: NSHostingController<AnyView>) {
        sizeObservation = controller.observe(
            \.preferredContentSize,
            options: [.new]
        ) { [weak self] _, change in
            guard let size = change.newValue, size.height > 0 else { return }
            // KVO can fire on a background thread — hop to main before touching UI.
            DispatchQueue.main.async { [weak self] in self?.resizeAndRepositionPanel() }
        }
    }

    // MARK: Combine subscriptions

    /// Starts all Combine subscriptions.
    ///
    /// Startup sequencing (critical — do not reorder):
    ///   1. LocalRunnerStore.shared.refresh() is called first to seed the local runner
    ///      list from disk. Without this, LocalRunnerStore.runners is empty when
    ///      RunnerStore.start() fires its first fetch(), causing buildInstallPathMap to
    ///      produce empty lookup maps and every busy runner to log
    ///      "no installPath — metrics=nil" for the lifetime of the session.
    ///   2. A one-shot sink on LocalRunnerStore.$isScanning waits for that first refresh
    ///      cycle to complete (isScanning flips false) before calling RunnerStore.start().
    ///      This guarantees the local runner list is fully populated before any API poll
    ///      attempts to enrich runners with install-path metrics.
    ///   3. The $runners sink (view-model reload) and the didUpdate sink are wired
    ///      independently and do not affect this ordering.
    private func setupCombineSubscriptions() {
        // $runners — local runner list changed on disk (added/removed runner config).
        LocalRunnerStore.shared.$runners
            .receive(on: DispatchQueue.main)
            .sink { [weak self] runners in
                guard let self else { return }
                log("AppDelegate › LocalRunnerStore.$runners fired — count=\(runners.count)")
                self.observable.reload()
            }
            .store(in: &cancellables)

        // Everything below makes live network calls — skip entirely in UI tests.
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == nil else {
            log("AppDelegate › UI_TESTING env set — skipping network subscriptions and poll start")
            return
        }

        // didUpdate — API poll cycle complete; refresh icon and view-model.
        RunnerStore.shared.didUpdate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                log("AppDelegate › didUpdate fired — panelIsOpen=\(self.panelIsOpen) actions=\(RunnerStore.shared.actions.count) jobs=\(RunnerStore.shared.jobs.count) runners=\(RunnerStore.shared.runners.count)")
                self.updateStatusIcon()
                self.observable.reload()
            }
            .store(in: &cancellables)

        // didMutate — scope changed; must restart the store entirely so it polls
        // the correct repos from the beginning.
        ScopeStore.shared.didMutate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard self != nil else { return }
                log("AppDelegate › ScopeStore.didMutate — restarting RunnerStore")
                RunnerStore.shared.start()
            }
            .store(in: &cancellables)

        // Seed LocalRunnerStore BEFORE starting the poll loop.
        //
        // RunnerStore.start() fires its first fetch() synchronously (no await before
        // the first buildInstallPathMap call). At that moment LocalRunnerStore.runners
        // is [] because no view has called refresh() yet. The result: empty lookup maps,
        // zero metrics for every busy runner, forever — until a manual Settings open.
        //
        // Fix: kick off a refresh() now, then start the poll loop only after the first
        // scan completes. We watch $isScanning: when it transitions false→true (scan
        // starts) then true→false (scan done), we fire RunnerStore.start() once and
        // cancel the observation via the stored cancellable.
        log("AppDelegate › startup — seeding LocalRunnerStore before first poll")
        var startupScanDone = false
        var scanSub: AnyCancellable?
        scanSub = LocalRunnerStore.shared.$isScanning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isScanning in
                guard let self else { return }
                log("AppDelegate › LocalRunnerStore.$isScanning=\(isScanning) startupScanDone=\(startupScanDone)")
                guard !startupScanDone else { return }
                // Wait for the scan to have started (true) and then finished (false).
                // This prevents the initial false→false no-op from triggering start().
                if !isScanning && LocalRunnerStore.shared.runners.count > 0 {
                    startupScanDone = true
                    log("AppDelegate › startup seed complete — localRunners=\(LocalRunnerStore.shared.runners.count) — starting RunnerStore poll loop")
                    scanSub?.cancel()
                    RunnerStore.shared.start()
                } else if !isScanning && LocalRunnerStore.shared.runners.count == 0 {
                    // Scan finished but found no runners — still start polling so
                    // GitHub runner list loads. buildInstallPathMap will have empty
                    // maps but that is expected when no runners are installed locally.
                    startupScanDone = true
                    log("AppDelegate › startup seed complete — no local runners found — starting RunnerStore poll loop anyway")
                    scanSub?.cancel()
                    RunnerStore.shared.start()
                }
            }
        LocalRunnerStore.shared.refresh()
        log("AppDelegate › LocalRunnerStore.refresh() triggered — waiting for scan to complete before starting poll")
        // Store the subscription so it lives until it self-cancels above.
        if let sub = scanSub {
            sub.store(in: &cancellables)
        }
    }
}
