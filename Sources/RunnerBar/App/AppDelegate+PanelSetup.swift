// AppDelegate+PanelSetup.swift
// RunnerBar
import AppKit
import Combine
import SwiftUI

// MARK: - AppDelegate + Panel Setup
//
// Owns NSPanel construction, KVO on preferredContentSize, and Combine
// subscriptions that drive icon/store updates.
// Called once from applicationDidFinishLaunching via setupPanel().
//
// ❌ NEVER inline this back into AppDelegate.swift.
// ❌ NEVER call setupPanel() more than once.
//
// CORNER RADIUS CONTRACT:
// contentView.layer.mask = CAShapeLayer (rounded rect path).
// ❌ NEVER use layer.cornerRadius + masksToBounds=true  → clips child NSWindows (sheets).
// ❌ NEVER use layer.cornerRadius + masksToBounds=false → radius has no visual effect.
// ✅ CAShapeLayer.mask clips pixel drawing only; child NSWindows are unaffected.
// The mask path MUST be updated in resizeAndRepositionPanel() whenever size changes.

/// Extension responsible for NSPanel construction, KVO observation, and
/// Combine subscriptions that drive icon and store updates.
extension AppDelegate {

    // MARK: Panel construction

    /// Builds the NSPanel, embeds the SwiftUI hosting controller directly in the
    /// panel content view, wires KVO, and starts all Combine subscriptions.
    func setupPanel() {
        let controller = NSHostingController(rootView: mainView())
        controller.sizingOptions = .preferredContentSize
        controller.view.autoresizingMask = [.width, .height]
        controller.view.wantsLayer = true
        hostingController = controller

        let initW = Self.initPanelWidth
        let newPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: initW, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        newPanel.contentViewController = controller
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        let isUITesting = ProcessInfo.processInfo.environment["UI_TESTING"] != nil
        newPanel.level = isUITesting ? .floating : .popUpMenu
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.animationBehavior = .none
        newPanel.appearance = NSAppearance(named: .darkAqua)

        // Round the panel corners using a CAShapeLayer mask on contentView.layer.
        // This clips pixel drawing only — child NSWindows (sheets, popovers) are
        // outside the CALayer tree and are completely unaffected.
        // See docs/sheet-rectangle-corners.md for full rationale.
        newPanel.contentView?.wantsLayer = true
        newPanel.contentView?.layer?.backgroundColor =
            NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
        let maskLayer = CAShapeLayer()
        maskLayer.path = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: initW, height: 300),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        newPanel.contentView?.layer?.mask = maskLayer

        panel = newPanel

        setupKVO(controller: controller)
        setupCombineSubscriptions()
    }

    // MARK: KVO

    /// Observes `preferredContentSize` on the hosting controller and triggers
    /// a panel resize whenever the SwiftUI content height changes.
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

    /// Starts all Combine subscriptions: local runner reloads, remote runner
    /// store updates (icon + observable reload), and scope mutation restarts.
    private func setupCombineSubscriptions() {
        LocalRunnerStore.shared.$runners
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.observable.reload(localRunnerStore: LocalRunnerStore.shared)
            }
            .store(in: &cancellables)

        // Skip all network + keychain activity during UI tests.
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
