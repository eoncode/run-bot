// AppDelegate+PanelSetup.swift
// RunnerBar
import AppKit
import Combine
import SwiftUI

// MARK: - AppDelegate + Panel Setup
//
// Owns NSPanel construction, PanelChromeView wiring, KVO on
// preferredContentSize, and Combine subscriptions that drive icon/store updates.
// Called once from applicationDidFinishLaunching via setupPanel().
//
// ❌ NEVER inline this back into AppDelegate.swift.
// ❌ NEVER call setupPanel() more than once.

/// AppDelegate extension that builds the NSPanel, embeds the SwiftUI hosting controller,
/// wires KVO on `preferredContentSize`, and starts all Combine subscriptions.
extension AppDelegate {

    // MARK: Panel construction

    /// Builds the NSPanel, embeds the SwiftUI hosting controller inside
    /// PanelChromeView, wires KVO, and starts all Combine subscriptions.
    func setupPanel() {
        let controller = NSHostingController(rootView: mainView())
        controller.sizingOptions = .preferredContentSize
        controller.view.autoresizingMask = [.width, .height]

        // MARK: Hosting view transparency
        //
        // NSHostingController's backing NSView is opaque by default — it paints a solid
        // system background colour over whatever is beneath it (NSGlassEffectView in our case),
        // producing the flat grey appearance on the main panel's cold open.
        //
        // After navigating back from Settings, hostingController.rootView is replaced via
        // navigate(to:), which internally resets the backing view's drawing state to
        // transparent — which is why the panel looks correct after that navigation round-trip.
        //
        // Setting wantsLayer = true and layer.backgroundColor = .clear immediately after
        // creation makes cold-open Main match the post-navigation appearance permanently.
        //
        // ❌ NEVER remove these two lines — main panel goes grey on cold open without them.
        // ❌ NEVER set isOpaque = true — re-enables the opaque fill.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
        controller.view.wantsLayer = true
        controller.view.layer?.backgroundColor = CGColor.clear

        hostingController = controller

        let initW = Self.initPanelWidth
        let chromeView = PanelChromeView(
            frame: NSRect(x: 0, y: 0, width: initW, height: 300 + arrowHeight)
        )
        chromeView.addSubview(controller.view)
        chrome = chromeView

        let newPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: initW, height: 300 + arrowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.contentView = chromeView
        newPanel.isOpaque = false
        newPanel.backgroundColor = NSColor(white: 1, alpha: 0.001)
        newPanel.hasShadow = true
        newPanel.level = .popUpMenu
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.animationBehavior = .none
        panel = newPanel

        setupKVO(controller: controller)
        setupCombineSubscriptions()
    }

    // MARK: KVO

    /// Installs KVO on `controller.preferredContentSize` to trigger panel resize
    /// whenever the SwiftUI content height changes.
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

    /// Wires Combine subscriptions for `LocalRunnerStore`, `RunnerStore.didUpdate`,
    /// and `ScopeStore.didMutate` so the status icon and view model stay in sync.
    private func setupCombineSubscriptions() {
        LocalRunnerStore.shared.$runners
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.observable.reload(localRunnerStore: LocalRunnerStore.shared)
            }
            .store(in: &cancellables)

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
