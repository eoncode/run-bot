# Sheet Rectangle Corners Bug

> **Symptom:** The main panel loses its rounded corners and shows sharp rectangular
> corners whenever a SwiftUI `.sheet` (or `.popover`) is presented over it.

---

## Root Cause

The panel is a borderless `NSPanel`. Its visual shape is produced by setting
`cornerRadius` on `contentView?.layer`. Two ways to enforce that radius exist:

| Approach | How it clips | Effect on child NSWindows |
|---|---|---|
| `layer.cornerRadius` + `masksToBounds = true` | Clips entire CALayer subtree | **Clips child `NSWindow`s too** — sheet appears chopped / invisible |
| `layer.cornerRadius` + `masksToBounds = false` | Draws radius on layer but does NOT clip | Radius has **no visual effect on the window shape** — corners are square |

Both approaches fail for our use-case. `masksToBounds = true` breaks sheets.
`masksToBounds = false` makes the radius invisible.

The commit comment in `AppDelegate+PanelSetup.swift` at the time of discovery read:
```
masksToBounds=true clips child NSWindows (popovers/sheets) — cornerRadius renders fine without it
```
This was incorrect: `cornerRadius` does **not** render fine without `masksToBounds = true`.
The panel window shape is rectangular regardless of `cornerRadius` when
`masksToBounds = false`. The rounded look that appeared during testing was likely
from `PanelChrome`'s separate visual-effects layer that was subsequently removed.

---

## Why `CALayer.mask` Solves It

`CALayer.mask` is a compositing mask: it clips what the layer **draws** (pixels)
but has no effect on `NSView` or `NSWindow` hierarchies. Child `NSWindow`s (sheets)
are not part of the layer tree at all — they are separate OS windows. So:

- `contentView.layer.mask = shapeLayer` → panel corners are visually rounded ✅
- Sheet child window is a separate `NSWindow` — entirely unaffected by the mask ✅
- `masksToBounds` can stay `false` (or be omitted) — not needed ✅

---

## The Fix

In `AppDelegate+PanelSetup.swift`, replace:

```swift
// ❌ OLD — broken
newPanel.contentView?.wantsLayer = true
newPanel.contentView?.layer?.cornerRadius = cornerRadius
newPanel.contentView?.layer?.masksToBounds = false
newPanel.contentView?.layer?.backgroundColor = ...
```

With:

```swift
// ✅ NEW — CAShapeLayer mask
newPanel.contentView?.wantsLayer = true
newPanel.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
let maskLayer = CAShapeLayer()
maskLayer.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: initW, height: 300),
                        cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
newPanel.contentView?.layer?.mask = maskLayer
```

And update the mask path whenever the panel resizes (in `resizeAndRepositionPanel()`):

```swift
if let mask = panel?.contentView?.layer?.mask as? CAShapeLayer {
    mask.path = CGPath(roundedRect: CGRect(origin: .zero, size: newSize),
                       cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
}
```

---

## Rules Going Forward

- **Never** use `layer.cornerRadius + masksToBounds = true` on `contentView` — clips sheets.
- **Never** use `layer.cornerRadius + masksToBounds = false` — no visual effect on window shape.
- **Always** use `CAShapeLayer` mask on `contentView.layer` for panel corner shaping.
- Update the mask path in `resizeAndRepositionPanel()` whenever panel size changes.
- Do not add `NSVisualEffectView` as a chrome layer underneath — it fights with the mask.

---

*Discovered: 2026-05-29. Branch: fix/inline-sheet-overlays. Issue context: #inline-sheets.*
