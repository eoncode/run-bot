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
// CHROME NOTE (#1017):
// PanelChromeView has been removed. The panel uses native window-server rounded
// corners: backgroundColor = .clear + isOpaque = false on a borderless NSPanel
// gives the system HUD appearance including rounded corners, drawn below the
// layer tree. This survives SwiftUI .sheet attachment without going rectangular.
//
// Liquid glass / vibrancy is applied as a SwiftUI .background(.regularMaterial)
// in PanelMainView — not as an AppKit layer.
//
// ❌ NEVER add panel.appearance = NSAppearance(...) — forces appearance on child
//    sheet windows and breaks their system chrome.
// ❌ NEVER add contentView.layer.cornerRadius — fights AppKit sheet compositing.
// ❌ NEVER add contentView.layer.masksToBounds — clips child NSWindows.
// ❌ NEVER add contentView.layer.backgroundColor — conflicts with clear panel bg.

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
        hostingController = controller

        let initW = Self.initPanelWidth
        let newPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: initW, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        newPanel.contentViewController = controller
        // backgroundColor = .clear + isOpaque = false → window server draws native
        // rounded corners on the borderless panel. No CALayer manipulation needed.
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        let isUITesting = ProcessInfo.processInfo.environment["UI_TESTING"] != nil
        newPanel.level = isUITesting ? .floating : .popUpMenu
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.animationBehavior = .none
        // No appearance override — let the system / user appearance propagate
        // naturally to child windows (sheets).

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
                log("AppDelegate \u{203a} didUpdate fired \u{2014} panelIsOpen=\(self.panelIsOpen) actions=\(RunnerStore.shared.actions.count) jobs=\(RunnerStore.shared.jobs.count)")
                self.updateStatusIcon()
                self.observable.reload(localRunnerStore: LocalRunnerStore.shared)
            }
            .store(in: &cancellables)

        RunnerStore.shared.start()

        ScopeStore.shared.didMutate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard self != nil else { return }
                log("AppDelegate \u{203a} ScopeStore.didMutate \u{2014} restarting RunnerStore")
                RunnerStore.shared.start()
            }
            .store(in: &cancellables)
    }
}
