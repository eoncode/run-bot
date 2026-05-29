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
// SIZE NOTE:
// popover.contentSize is updated (both width AND height) via KVO on
// NSHostingController.preferredContentSize. The initial size below is
// a placeholder; it is overwritten immediately after show() by
// resizeAndRepositionPanel(). Updating contentSize resizes the popover
// in-place — the arrow stays pinned to the original positioningRect.
// ❌ NEVER call popover.show() again on resize — that re-anchors and jumps.

/// Extension responsible for NSPopover construction, KVO, and Combine subscriptions.
extension AppDelegate {

    // MARK: Popover construction

    /// Builds the NSPopover, embeds the SwiftUI hosting controller, wires KVO
    /// and Combine subscriptions.
    func setupPanel() {
        let controller = NSHostingController(rootView: mainView())
        controller.sizingOptions = .preferredContentSize
        hostingController = controller

        let newPopover = NSPopover()
        newPopover.contentViewController = controller
        // Placeholder size — overwritten by resizeAndRepositionPanel() after show().
        newPopover.contentSize = NSSize(width: 480, height: 300)
        // animates = false prevents size-change animation on KVO updates.
        newPopover.animates = false
        // .applicationDefined: we manage show/hide ourselves via togglePanel().
        newPopover.behavior = .applicationDefined

        popover = newPopover

        setupKVO(controller: controller)
        setupCombineSubscriptions()
    }

    // MARK: KVO

    /// Observes `preferredContentSize` and updates both width and height.
    /// Updating contentSize alone resizes in-place without moving the arrow anchor.
    private func setupKVO(controller: NSHostingController<AnyView>) {
        sizeObservation = controller.observe(
            \.preferredContentSize,
            options: [.new]
        ) { [weak self] _, change in
            guard let size = change.newValue, size.height > 0 else { return }
            DispatchQueue.main.async { [weak self] in self?.resizeAndRepositionPanel() }
        }
    }

    // MARK: Combine subscriptions

    /// Starts all Combine subscriptions.
    private func setupCombineSubscriptions() {
        LocalRunnerStore.shared.$runners
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.observable.reload(localRunnerStore: LocalRunnerStore.shared)
            }
            .store(in: &cancellables)

        guard ProcessInfo.processInfo.environment["UI_TESTING"] == nil else { return }

        RunnerStore.shared.didUpdate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                log("AppDelegate › didUpdate fired — panelIsOpen=\(self.panelIsOpen) actions=\(RunnerStore.shared.actions.count) jobs=\(RunnerStore.shared.jobs.count)")
                self.updateStatusIcon()
                self.observable.reload(localRunnerStore: LocalRunnerStore.shared)
            }
            .store(in: &cancellables)

        RunnerStore.shared.start()

        ScopeStore.shared.didMutate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard self != nil else { return }
                log("AppDelegate › ScopeStore.didMutate — restarting RunnerStore")
                RunnerStore.shared.start()
            }
            .store(in: &cancellables)
    }
}
