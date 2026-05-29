// AppDelegate.swift
// RunnerBar
import AppKit
import Combine
import SwiftUI

// MARK: - NSPopover architecture note
//
// ⚠️ NSPopover is used instead of NSPanel as of fix/#1017.
//
// WHY NSPopover instead of NSPanel:
// NSPanel with custom CAShapeLayer masking or cornerRadius+masksToBounds
// loses its rounded corners whenever a SwiftUI .sheet is presented as a
// child NSWindow. AppKit's sheet attachment path modifies the parent
// window's CALayer tree, discarding any mask or masksToBounds we set.
// NSPopover uses NSPopoverWindowFrame, a dedicated window class whose chrome
// is drawn by the window-server compositor — completely unaffected by sheet
// attachment. Rounded corners survive .sheet natively.
//
// HOW THE POPOVER WORKS:
// 1. NSPopover with animates=false, behavior=.applicationDefined.
// 2. Shown via popover.show(relativeTo: button.bounds, of: button,
//    preferredEdge: .minY) — anchors to the status bar button.
// 3. Size is driven by KVO on NSHostingController.preferredContentSize.
//    ⚠️ WIDTH IS FIXED at popoverWidth. Only height changes.
//    Changing width on a visible NSPopover causes it to jump laterally
//    (re-anchoring from center). We prevent this by always using
//    popoverWidth regardless of SwiftUI's reported width.
// 4. Dismiss: popover.performClose(nil) or NSEvent global monitor
//    + NSWorkspace app-switch notification (same as before).
//
// TEXT INPUT:
// NSPopover windows are key-capable natively. For views that have
// TextFields, call NSApp.activate(ignoringOtherApps: true) before
// navigation — this promotes the popover to key window.
// ❌ NEVER call panel.makeKeyAndOrderFront(nil) — panel no longer exists.
//
// WIDTH CONTRACT:
// popoverWidth is the single fixed width for the popover.
// SwiftUI views declare their own minWidth/idealWidth but the popover
// contentSize.width is always locked to popoverWidth.
// ❌ NEVER update contentSize.width on resize — lateral jump regression.
// ❌ NEVER set popoverWidth > 900.
// ❌ NEVER set popoverWidth < 280.
//
// PANELVISIBILITYSTATE:
// panelVisibilityState.isOpen is driven by NSPopoverDelegate callbacks.
// ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
// ❌ NEVER pass as a plain Bool prop to PanelMainView.
// See ARCHITECTURE.md §panelVisibilityState.

// MARK: - AppDelegate

// ⚠️ @MainActor isolation — see ARCHITECTURE.md §@MainActor isolation.
// ❌ NEVER remove @MainActor from this class declaration.
// ❌ NEVER remove `nonisolated` from enrichStepsIfNeeded.
/// Manages AppDelegate state and behaviour.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // NOTE: Properties are `internal` (not `private`) because Swift `private`
    // does not cross file boundaries. AppDelegate+Navigation.swift requires
    // read/write access to all of them.

    /// The statusItem property.
    var statusItem: NSStatusItem?
    /// The popover replacing the old KeyablePanel.
    var popover: NSPopover?
    /// The hostingController property.
    var hostingController: NSHostingController<AnyView>?
    /// The observable constant.
    let observable = RunnerViewModel()
    /// The savedNavState property.
    var savedNavState: NavState?
    /// Mirrors popover.isShown — kept for compatibility with navigation code.
    var panelIsOpen = false

    /// The eventMonitor property.
    var eventMonitor: Any?
    /// The sizeObservation property.
    var sizeObservation: NSKeyValueObservation?
    /// The workspaceObserver property.
    var workspaceObserver: Any?
    /// The cancellables property.
    var cancellables = Set<AnyCancellable>()

    // Regression guard — see ARCHITECTURE.md §panelVisibilityState.
    // ❌ NEVER remove. ❌ NEVER remove from wrapEnv(). ❌ NEVER pass as plain Bool to PanelMainView.
    /// The panelVisibilityState constant.
    let panelVisibilityState = PanelVisibilityState()

    /// Fixed popover width. Width never changes on a visible popover — lateral jump prevention.
    /// ❌ NEVER update contentSize.width after initial show.
    static let popoverWidth: CGFloat = 480

    /// Maximum popover height (85% of visible screen).
    var maxHeight: CGFloat {
        (statusItemScreen.visibleFrame.height * 0.85)
    }

    /// The screen the status item lives on.
    var statusItemScreen: NSScreen {
        statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: - Sheet guard
    //
    // SwiftUI .sheet() attaches as a child NSWindow to the popover's window.
    // Clicks inside the sheet land outside the popover frame, which would
    // trigger the global mouse-down monitor and call closePanel() immediately.
    // ❌ NEVER remove this check from the eventMonitor block.
    // ⚠️ Do NOT use this guard in workspaceObserver — app-switching must always
    // hide the panel, even when a sheet is open. See #1015.
    /// Returns true when a SwiftUI sheet is currently presented over the popover.
    private var hasActiveSheet: Bool {
        guard let popoverWindow = popover?.contentViewController?.view.window else { return false }
        return !popoverWindow.sheets.isEmpty
    }

    // MARK: - Environment injection

    // Regression guard — see ARCHITECTURE.md §panelVisibilityState and §wrapEnv.
    // ❌ NEVER bypass. ❌ NEVER remove .environmentObject(panelVisibilityState).
    // swiftlint:disable:next missing_docs
    func wrapEnv<V: View>(_ view: V) -> AnyView {
        AnyView(view.environmentObject(panelVisibilityState))
    }

    // MARK: - App lifecycle

    /// Sets activation policy during UI tests so XCTest can see windows.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] != nil else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Performs the applicationDidFinishLaunching operation.
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureGHAPI(
            { endpoint in ghAPI(endpoint) },
            isRateLimited: { ghIsRateLimited }
        )
        setupStatusItem()
        setupPanel()
    }

    // MARK: - OAuth URL callback (#326)

    /// Performs the application operation.
    func application(_ _: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme == "runnerbar" && $0.host == "oauth" })
        else { return }
        OAuthService.shared.handleCallback(url)
    }

    // MARK: - Popover resize

    // Regression guard — see ARCHITECTURE.md §Panel Lifecycle.
    // ❌ WIDTH IS NEVER CHANGED HERE — only height. Lateral jump prevention.
    // swiftlint:disable:next missing_docs
    func resizeAndRepositionPanel() {
        guard panelIsOpen, let popover, let controller = hostingController else { return }
        let preferred = controller.preferredContentSize
        guard preferred.height > 0 else { return }
        let newH = min(max(preferred.height, 60), maxHeight)
        // Only update if height actually changed to avoid redundant layout passes.
        if abs(popover.contentSize.height - newH) > 1 {
            popover.contentSize = NSSize(width: Self.popoverWidth, height: newH)
        }
    }

    // MARK: - Navigation

    // swiftlint:disable:next missing_docs
    func navigate(to view: AnyView) {
        hostingController?.rootView = view
        resizeAndRepositionPanel()
    }

    // MARK: - Make key for text input

    // NSPopover windows are key-capable natively. Activating the app is
    // sufficient to allow TextFields to receive first-responder.
    // ❌ NEVER call panel.makeKeyAndOrderFront — panel no longer exists.
    /// Promotes the popover window to key so TextFields receive input.
    func makeKeyForTextInput() {
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Dismiss

    /// Closes the popover and resets all state.
    func closePanel() {
        guard panelIsOpen else { return }
        popover?.performClose(nil)
        panelIsOpen = false
        panelVisibilityState.isOpen = false
        removeEventMonitor()
        removeWorkspaceObserver()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let preserved = self.savedNavState
            self.hostingController?.rootView = self.mainView()
            self.savedNavState = preserved
        }
    }

    /// Hides the popover without resetting the view hierarchy. (#1015)
    func hidePanel() {
        guard panelIsOpen else { return }
        popover?.performClose(nil)
        panelIsOpen = false
        panelVisibilityState.isOpen = false
        removeEventMonitor()
        removeWorkspaceObserver()
    }

    /// Performs the removeEventMonitor operation.
    func removeEventMonitor() {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor); eventMonitor = nil }
    }

    /// Performs the removeWorkspaceObserver operation.
    func removeWorkspaceObserver() {
        if let opt = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(opt)
            workspaceObserver = nil
        }
    }

    // MARK: - Toggle

    /// Performs the togglePanel operation.
    @objc func togglePanel() {
        if panelIsOpen {
            closePanel()
        } else {
            openPanel()
        }
    }

    // MARK: - Open

    /// Shows the popover anchored to the status bar button.
    func openPanel() {
        guard let button = statusItem?.button, let popover else { return }

        log("AppDelegate › openPanel — seeding observable: actions=\(RunnerStore.shared.actions.count) jobs=\(RunnerStore.shared.jobs.count) localRunners=\(LocalRunnerStore.shared.runners.count)")
        observable.reload(localRunnerStore: LocalRunnerStore.shared)

        panelIsOpen = true
        panelVisibilityState.isOpen = true

        // Set initial contentSize before show to avoid the popover appearing
        // at a wrong size for one frame. Width is always locked.
        let initH: CGFloat = 300
        popover.contentSize = NSSize(width: Self.popoverWidth, height: initH)

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Activate so TextFields can receive input immediately.
        NSApp.activate(ignoringOtherApps: true)

        // Resize to actual SwiftUI content size after show.
        resizeAndRepositionPanel()

        if let saved = savedNavState, let restored = validatedView(for: saved) {
            navigate(to: restored)
        }

        // Skip dismiss monitors during UI tests.
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == nil else { return }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let popover = self.popover else { return }
            // ❌ NEVER remove the hasActiveSheet guard — sheets attach as child
            // windows; clicks inside them would otherwise trigger closePanel().
            guard !self.hasActiveSheet else { return }
            let loc = event.locationInWindow
            let screenLoc = event.window?.convertToScreen(
                NSRect(origin: loc, size: .zero)
            ).origin ?? loc
            guard let popoverWindow = popover.contentViewController?.view.window else { return }
            if !popoverWindow.frame.contains(screenLoc) { self.closePanel() }
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if NSRunningApplication.current != NSWorkspace.shared.frontmostApplication {
                Task { @MainActor [weak self] in self?.hidePanel() }
            }
        }
    }
}
