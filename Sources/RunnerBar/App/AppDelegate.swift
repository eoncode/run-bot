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
//    preferredEdge: .minY) — anchors to the status bar button once on open.
// 3. Size driven by KVO on NSHostingController.preferredContentSize.
//    ⚠️ Do NOT call popover.show() again on resize — re-anchors and jumps.
// 4. Dismiss: popover.performClose(nil) via event monitor + workspace observer.
//
// SHEET ORPHAN PROBLEM AND FIX — read before touching closePanel()/hidePanel():
//
// NSPopover.performClose() does NOT remove child sheet NSWindows. They become
// orphans: still attached, still intercepting all mouse events, app frozen.
//
// FIX: Before performClose(), toggle panelVisibilityState.dismissSheetsTrigger.
// SettingsView observes this and nils all its sheet bindings. SwiftUI tears
// down the sheet NSWindow through its own presentation path. After one runloop
// tick (Task { await MainActor.run {} }), call performClose() — sheet is gone.
//
// ❌ NEVER call performClose() synchronously on the same tick as the trigger.
// ❌ NEVER remove the trigger toggle from closePanel() or hidePanel().
// ❌ NEVER remove the .onChange observer in SettingsView.

// ⚠️ @MainActor isolation — see ARCHITECTURE.md §@MainActor isolation.
// ❌ NEVER remove @MainActor from this class declaration.
/// Manages AppDelegate state and behaviour.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
    /// Mirrors popover.isShown.
    var panelIsOpen = false

    /// The eventMonitor property.
    var eventMonitor: Any?
    /// The sizeObservation property.
    var sizeObservation: NSKeyValueObservation?
    /// The workspaceObserver property.
    var workspaceObserver: Any?
    /// The cancellables property.
    var cancellables = Set<AnyCancellable>()

    /// The panelVisibilityState constant.
    let panelVisibilityState = PanelVisibilityState()

    /// Minimum popover content width.
    static let minWidth: CGFloat = 280

    /// Maximum popover content width.
    var maxWidth: CGFloat { min(900, statusItemScreen.visibleFrame.width * 0.9) }

    /// Maximum popover height.
    var maxHeight: CGFloat { statusItemScreen.visibleFrame.height * 0.85 }

    /// The screen the status item lives on.
    var statusItemScreen: NSScreen {
        statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Returns true when a SwiftUI sheet is currently presented over the popover.
    var hasActiveSheet: Bool {
        guard let win = popover?.contentViewController?.view.window else { return false }
        return !win.sheets.isEmpty
    }

    // MARK: - Environment injection
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

    /// Performs the application operation.
    func application(_ _: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme == "runnerbar" && $0.host == "oauth" })
        else { return }
        OAuthService.shared.handleCallback(url)
    }

    // MARK: - Popover resize
    // swiftlint:disable:next missing_docs
    func resizeAndRepositionPanel() {
        guard panelIsOpen, let popover, let controller = hostingController else { return }
        let preferred = controller.preferredContentSize
        guard preferred.height > 0 else { return }
        let newW = min(max(preferred.width > 0 ? preferred.width : Self.minWidth, Self.minWidth), maxWidth)
        let newH = min(max(preferred.height, 60), maxHeight)
        let currentSize = popover.contentSize
        if abs(currentSize.width - newW) > 1 || abs(currentSize.height - newH) > 1 {
            popover.contentSize = NSSize(width: newW, height: newH)
        }
    }

    // MARK: - Navigation
    // swiftlint:disable:next missing_docs
    func navigate(to view: AnyView) {
        hostingController?.rootView = view
        resizeAndRepositionPanel()
    }

    /// Promotes the app to key so TextFields in the popover receive input.
    func makeKeyForTextInput() { NSApp.activate(ignoringOtherApps: true) }

    // MARK: - Dismiss helpers

    /// Signals SwiftUI views to dismiss their sheets, then closes the popover
    /// on the next runloop tick so the sheet NSWindow is gone before performClose().
    ///
    /// ❌ NEVER call performClose() synchronously here — SwiftUI needs one tick.
    private func triggerSheetsAndClose() {
        panelVisibilityState.dismissSheetsTrigger.toggle()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.popover?.performClose(nil)
            self.panelIsOpen = false
            self.panelVisibilityState.isOpen = false
            self.removeEventMonitor()
            self.removeWorkspaceObserver()
        }
    }

    // MARK: - Close / Hide

    /// Explicit close (back button, Escape). Resets rootView to main on next tick.
    func closePanel() {
        guard panelIsOpen else { return }
        savedNavState = nil
        triggerSheetsAndClose()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hostingController?.rootView = self.mainView()
        }
    }

    /// Outside-tap / workspace-switch hide. Does NOT reset rootView so nav state
    /// is preserved for re-open.
    func hidePanel() {
        guard panelIsOpen else { return }
        triggerSheetsAndClose()
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
        if panelIsOpen { closePanel() } else { openPanel() }
    }

    // MARK: - Open
    /// Shows the popover anchored to the status bar button.
    func openPanel() {
        guard let button = statusItem?.button, let popover else { return }

        log("AppDelegate › openPanel — seeding observable")
        observable.reload(localRunnerStore: LocalRunnerStore.shared)

        panelIsOpen = true
        panelVisibilityState.isOpen = true

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        resizeAndRepositionPanel()

        // Only navigate if no sheet is currently active. If a sheet was open
        // when the user tapped outside (hidePanel path), rootView is already
        // correct and the sheet binding is still true — SwiftUI will re-present
        // it automatically. Navigating here would replace rootView with a new
        // struct and reset all @State, losing the sheet.
        if let saved = savedNavState, !hasActiveSheet {
            if let restored = validatedView(for: saved) {
                navigate(to: restored)
            }
        }

        guard ProcessInfo.processInfo.environment["UI_TESTING"] == nil else { return }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let popover = self.popover else { return }
            let loc = event.locationInWindow
            let screenLoc = event.window?.convertToScreen(
                NSRect(origin: loc, size: .zero)
            ).origin ?? loc
            guard let popoverWindow = popover.contentViewController?.view.window else { return }
            let inSheet = popoverWindow.sheets.contains { $0.frame.contains(screenLoc) }
            if !popoverWindow.frame.contains(screenLoc) && !inSheet {
                self.hidePanel()
            }
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
