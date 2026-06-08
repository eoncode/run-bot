// NSWindowGrabber.swift
// RunnerBar
//
// NSViewRepresentable that captures the hosting NSWindow at view-mount time.
// Used by ScopeEditSheet to obtain a stable NSWindow reference for
// beginSheetModal — avoiding the race where NSApp.keyWindow is nil at
// button-tap time. (#1193)
import AppKit
import SwiftUI

// MARK: - NSWindowGrabber (AppKit)

/// An `NSView` subclass that calls `executeBlock` as soon as the view is
/// inserted into a window hierarchy. The window reference is available
/// before any user interaction, making it safe to use with
/// `NSOpenPanel.beginSheetModal(for:)`.
public class NSWindowGrabber: NSView {
    let executeBlock: (_ window: NSWindow?) -> Void

    init(executeBlock: @escaping (_ window: NSWindow?) -> Void) {
        self.executeBlock = executeBlock
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Called by AppKit when the view moves into (or out of) a window.
    /// We forward the current window — non-nil on insertion, nil on removal.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        executeBlock(self.window)
    }
}

// MARK: - WindowGrabber (SwiftUI wrapper)

/// A zero-size SwiftUI view that reports its hosting `NSWindow` via a closure
/// the moment the view is attached to the window hierarchy.
///
/// Usage:
/// ```swift
/// @State private var hostWindow: NSWindow?
///
/// var body: some View {
///     MyContent()
///         .background(WindowGrabber { hostWindow = $0 })
/// }
/// ```
public struct WindowGrabber: NSViewRepresentable {
    public var execute: (_ window: NSWindow?) -> Void

    public init(execute: @escaping (_ window: NSWindow?) -> Void) {
        self.execute = execute
    }

    public func makeNSView(context: Context) -> NSWindowGrabber {
        NSWindowGrabber(executeBlock: execute)
    }

    public func updateNSView(_ nsView: NSWindowGrabber, context: Context) {}
}
