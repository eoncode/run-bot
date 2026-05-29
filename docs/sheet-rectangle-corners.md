# Sheet Rectangle Corners Bug

> **Symptom:** The main panel loses its rounded corners and shows sharp rectangular
> corners whenever a SwiftUI `.sheet` (or `.popover`) is presented over it.

---

## Root Cause — Attempt 1: `layer.cornerRadius` on the panel

The panel is a borderless `NSPanel`. Initial attempts set `cornerRadius` on
`contentView?.layer` with varying `masksToBounds` values:

| Approach | How it clips | Effect on child NSWindows |
|---|---|---|
| `layer.cornerRadius` + `masksToBounds = true` | Clips entire CALayer subtree | **Clips child `NSWindow`s too** — sheet appears chopped / invisible |
| `layer.cornerRadius` + `masksToBounds = false` | Draws radius on layer but does NOT clip | Radius has **no visual effect on the window shape** — corners are square |

Both approaches fail. The commit comment at the time read:
```
masksToBounds=true clips child NSWindows — cornerRadius renders fine without it
```
This was incorrect: `cornerRadius` does **not** render fine without `masksToBounds = true`.
The panel window shape is rectangular regardless. The rounded look that briefly
appeared was from `PanelChrome`'s separate visual-effects layer that was later removed.

---

## Fix 1 — `CAShapeLayer` mask on the panel (panel corners ✅, sheet corners ❌)

`CALayer.mask` compositing clips what the layer **draws** (pixels) but has no
effect on `NSView` or `NSWindow` hierarchies. Child `NSWindow`s are separate OS
windows — outside the CALayer tree entirely.

```swift
// ✅ Panel corners: CAShapeLayer mask
newPanel.contentView?.wantsLayer = true
newPanel.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
let maskLayer = CAShapeLayer()
maskLayer.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: initW, height: 300),
                        cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
newPanel.contentView?.layer?.mask = maskLayer
```

Also update the mask path whenever the panel resizes (in `resizeAndRepositionPanel()`):

```swift
if let mask = panel?.contentView?.layer?.mask as? CAShapeLayer {
    mask.path = CGPath(roundedRect: CGRect(origin: .zero, size: newSize),
                       cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
}
```

Result: panel corners are rounded ✅. But sheet corners remain square ❌ because
SwiftUI's `.sheet` creates a brand-new sibling `NSWindow` — entirely outside the
panel's CALayer tree.

---

## Root Cause — Attempt 2: sheet corners still square

When SwiftUI presents a `.sheet`, it calls `NSWindow.addChildWindow(_:ordered:)`
under the hood. This creates a **brand-new `NSWindow`** — a sibling of the panel
in AppKit's window hierarchy, not a subview. That child window owns its own,
completely separate layer tree. The `CAShapeLayer` mask on the panel's
`contentView.layer` has zero effect on it.

Also ruled out: `NSWindowDelegate.window(_:willPositionSheet:using:)` — this
only fires for AppKit sheets via `NSWindow.beginSheet(_:completionHandler:)`.
SwiftUI bypasses it entirely and goes straight through `addChildWindow(_:ordered:)`.

---

## Fix 2 — `NSWindowDelegate.window(_:didAddChildWindow:)` (sheet corners ✅)

Wire `AppDelegate` as the panel's `NSWindowDelegate`. AppKit fires
`window(_:didAddChildWindow:)` the moment any child window is added — including
SwiftUI sheet windows. Round the child's own `contentView.layer` there.

```swift
// In AppDelegate+PanelSetup.swift — setupPanel():
newPanel.delegate = self

// Extension at bottom of AppDelegate+PanelSetup.swift:
extension AppDelegate: NSWindowDelegate {
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
```

### Why each line

| Line | Reason |
|---|---|
| `wantsLayer = true` | Ensures the layer exists before mutation |
| `cornerRadius = cornerRadius` | Matches the 10 pt panel chrome radius from `PanelChrome.swift` |
| `masksToBounds = true` | Clips the sheet's own content to the rounded rect — correct here, this IS the outermost surface |
| `isOpaque = false` | Required for transparent corners — without this a white rectangle shows through |
| `backgroundColor = .clear` | Removes the default window background fill so corner transparency works |
| `DispatchQueue.main.async` | SwiftUI finishes configuring the child window's layer slightly after the delegate fires; defer one tick to guarantee the layer is initialised |

### Why `willPositionSheet` was NOT used

`NSWindowDelegate.window(_:willPositionSheet:using:)` only fires for AppKit
sheets presented via `NSWindow.beginSheet(_:completionHandler:)`. SwiftUI's
`.sheet` bypasses this entirely and uses `addChildWindow(_:ordered:)` —
hence `didAddChildWindow` is the correct hook.

---

## Rules Going Forward

- **Never** `layer.cornerRadius + masksToBounds=true` on `contentView` — clips sheets.
- **Never** `layer.cornerRadius + masksToBounds=false` — no visual effect on window shape.
- **Always** `CAShapeLayer` mask on `contentView.layer` for the panel's own corners.
- **Always** update the mask path in `resizeAndRepositionPanel()` on every resize.
- **Always** use `NSWindowDelegate.didAddChildWindow` to round sheet child windows.
- `masksToBounds=true` is correct on the **child** window; must stay absent/false on the **panel**.
- `cornerRadius` constant lives in `PanelChrome.swift` — shared by panel chrome and delegate.

---

*Discovered: 2026-05-29. Branch: fix/inline-sheet-overlays.*
