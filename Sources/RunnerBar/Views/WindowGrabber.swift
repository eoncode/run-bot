// WindowGrabber.swift
// RunnerBar
//
// Captures the NSWindow that hosts a SwiftUI view at layout time so it can be
// passed to NSOpenPanel.beginSheetModal(for:). Using NSApp.keyWindow at button-
// tap time is unreliable inside a sheet-in-popover stack (it can be nil or
// point at the wrong window). WindowGrabber fires at viewDidMoveToWindow which
// runs during layout, guaranteeing a valid reference before any user action.
//
// Usage:
//   @State private var hostWindow: NSWindow?
//   var body: some View {
//       MyContent()
//           .background(WindowGrabber { hostWindow = $0 })
//   }
//
// Then pass `hostWindow` to picker.beginSheetModal(for:).

import AppKit
import SwiftUI

// MARK: - NSWindowGrabber (AppKit backing view)

/// An invisible `NSView` subclass that reports its hosting `NSWindow` via a
/// callback whenever it is moved into or out of a window hierarchy.
final class NSWindowGrabber: NSView {
    private let onWindowChange: (NSWindow?) -> Void

    init(onWindowChange: @escaping (NSWindow?) -> Void) {
        self.onWindowChange = onWindowChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange(window)
    }
}

// MARK: - WindowGrabber (SwiftUI wrapper)

/// A zero-size `NSViewRepresentable` that captures the hosting `NSWindow` at
/// layout time and delivers it via `onWindowChange`. Attach it as a
/// `.background()` modifier on any SwiftUI view inside the target window.
public struct WindowGrabber: NSViewRepresentable {
    /// Called on the main thread when the view moves into or out of a window.
    /// `window` is non-nil while the view is in a window hierarchy.
    public let onWindowChange: (NSWindow?) -> Void

    public init(onWindowChange: @escaping (NSWindow?) -> Void) {
        self.onWindowChange = onWindowChange
    }

    public func makeNSView(context: Context) -> NSWindowGrabber {
        NSWindowGrabber(onWindowChange: onWindowChange)
    }

    public func updateNSView(_ nsView: NSWindowGrabber, context: Context) {}
}
