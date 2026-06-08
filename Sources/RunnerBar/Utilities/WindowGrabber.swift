// WindowGrabber.swift
// RunnerBar
//
// Captures the NSWindow that hosts a SwiftUI view the moment the view is
// inserted into the window hierarchy. Used to obtain a reliable NSWindow
// reference for `beginSheetModal(for:)` without racing against keyWindow
// changes.
//
// Usage:
//   .background(WindowGrabber { window in self.hostWindow = window })
//
// #1195 — required for NSOpenPanel.beginSheetModal inside NSPopover.

import AppKit
import SwiftUI

// MARK: - NSWindowGrabber (NSView subclass)

final class NSWindowGrabber: NSView {
    let onWindow: (NSWindow?) -> Void

    init(onWindow: @escaping (NSWindow?) -> Void) {
        self.onWindow = onWindow
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow(window)
    }
}

// MARK: - WindowGrabber (NSViewRepresentable)

struct WindowGrabber: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSWindowGrabber {
        NSWindowGrabber(onWindow: onWindow)
    }

    func updateNSView(_ nsView: NSWindowGrabber, context: Context) {}
}
