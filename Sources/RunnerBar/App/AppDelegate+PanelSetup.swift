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
//
// SHEET CORNER RADIUS:
// SwiftUI .sheet creates a sibling NSWindow via addChildWindow(_:ordered:).
// That window's corners are rounded in the NSWindowDelegate extension below.
// ❌ NEVER expect contentView.layer changes to affect a different NSWindow.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT.

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

        // Assign delegate so the NSWindowDelegate extension below can intercept
        // child windows (SwiftUI sheet windows) and round their corners.
        newPanel.delegate = self

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

// MARK: - NSWindowDelegate — child window corner rounding
//
// SwiftUI's .sheet modifier presents its content in a brand-new NSWindow that
// AppKit registers as a child of the panel via addChildWindow(_:ordered:).
// This fires window(_:didAddChildWindow:) on the panel's delegate.
//
// The CAShapeLayer mask on the panel's own contentView.layer has zero effect on
// the child window — it owns a completely separate layer tree rendered
// independently by the WindowServer. We must round the child's own contentView.
//
// Why async: SwiftUI finishes configuring the child window's layer slightly
// after the delegate call. Deferring one runloop tick ensures the layer exists
// and is fully initialised before mutation.
//
// Why masksToBounds=true on the child: the child is the outermost surface of
// the sheet — clipping its own content to the rounded rect is correct.
//
// ❌ NEVER set masksToBounds=true on the PANEL's own contentView — that clips
//    child NSWindows off-screen (they are in the layer tree at that level).
// ❌ NEVER remove this extension — sheets will regress to square corners.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT.
extension AppDelegate: NSWindowDelegate {
    /// Called by AppKit whenever a child window is added to the panel.
    /// Rounds the child window's corners to match the panel chrome (10 pt).
    func window(_ window: NSWindow, didAddChildWindow child: NSWindow) {
        DispatchQueue.main.async {
            child.contentView?.wantsLayer = true
            child.contentView?.layer?.cornerRadius = cornerRadius
            child.contentView?.layer?.masksToBounds = true
            child.isOpaque = false
            child.backgroundColor = .clear
        }
    }
}
