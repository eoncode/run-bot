# StatusBar Panel — What We Know, What Failed, New Strategy

This document is a living record of every approach tried for the RunnerBar
NSPanel visual chrome. Written to prevent re-trying failed solutions and to
establish a new strategy from first principles.

---

## Current Architecture (as of 2026-05-29)

**Window type:** `KeyablePanel : NSPanel`  
**Style mask:** `[.borderless, .nonactivatingPanel]`  
**Background:** `isOpaque = false`, `backgroundColor = .clear`  
**Chrome:** Custom `PanelChromeView` inserted as the NSPanel's content view  
**Backdrop:** `NSGlassEffectView` (macOS 26+) / `NSVisualEffectView(.hudWindow)` (earlier)  
**Arrow:** Custom bezier path clipped via `CAShapeLayer` mask on fxView  
**Corner radius:** `cornerRadius = 10`, applied via `CAShapeLayer` mask path — NOT via `layer.cornerRadius`  
**Content:** SwiftUI `NSHostingController` embedded inside `PanelChromeView`  
**Settings:** Previously presented as SwiftUI `.sheet` — now inline push navigation (this PR)

---

## Root Cause of the Rectangular Corners Problem

**The fundamental issue:** When SwiftUI's `.sheet` modifier is triggered on macOS,
it creates a new child `NSSheetWindow` attached to the parent window. This child window:

1. Has **its own separate `contentView`** — completely independent of our panel's
   `PanelChromeView`.
2. Gets default `NSWindow` chrome — rectangular, no rounding, no backdrop.
3. **Ignores** any `cornerRadius`, `masksToBounds`, or layer tricks we set on the
   parent panel's `contentView`.

When the sheet appears, macOS also **forces the parent window into "sheet hosting"
mode**, which redraws the parent window using a standard rectangular NSWindow
frame — overriding our custom `CAShapeLayer` mask and rounded corners.
This is why the settings window snaps to rectangular corners the moment a sheet
appears. It is not a bug in our chrome code — it is macOS enforcing its sheet
attachment model.

---

## What Has Been Tried and Failed

### ❌ Attempt 1: `masksToBounds = true` on contentView
**Tried:** Set `newPanel.contentView?.layer?.masksToBounds = true`  
**Failed:** Clips ALL child windows — popovers, sheets, tooltips all get clipped.  
**Verdict:** Never use `masksToBounds = true` on an NSPanel contentView.

### ❌ Attempt 2: `cornerRadius` directly on contentView layer
**Tried:** `newPanel.contentView?.layer?.cornerRadius = cornerRadius`  
**Failed:** No-op on transparent surface. No effect on child windows.  
**Verdict:** `layer.cornerRadius` on a transparent contentView is a no-op.

### ❌ Attempt 3: Setting `cornerRadius` on `PanelChromeView.layer`
**Tried:** Applying corner radius on our custom chrome layer  
**Failed:** `PanelChromeView` uses a `CAShapeLayer` mask — the two conflict.  
**Verdict:** Can't mix `layer.mask` and `layer.cornerRadius`.

### ❌ Attempt 4: SwiftUI `.sheet` for settings
**Tried:** Using SwiftUI's `.sheet` modifier on the main content view  
**Failed:** Creates a new child `NSSheetWindow`. Parent panel gets forced to
rectangular appearance by macOS sheet-hosting mode.  
**Verdict:** SwiftUI `.sheet` is fundamentally incompatible with a custom-chromed
borderless `NSPanel`. **Do not use.**

### ❌ Attempt 5: Nested `.sheet` inside `ScopeEditSheet` / `AddScopeSheet`
**Tried:** `.sheet` calls inside child views for BranchSelector, HookCommand, RepoSelector  
**Failed:** Each one creates another child NSWindow layer. Cascading chrome destruction.  
**Verdict:** Same root cause. Eliminated in this PR by inline push navigation.

---

## New Strategy: Inline Push Navigation (Implemented in this PR)

Every view that previously used `.sheet` now uses a local nav-state enum that
drives a `ZStack` with `.move(edge:)` transitions. No child windows are ever created.

```swift
// PATTERN — replaces every .sheet call
enum MySubScreen { case main, detail }
@State private var subScreen: MySubScreen = .main

var body: some View {
    ZStack {
        if subScreen == .main {
            mainContent
                .transition(.move(edge: .leading))
        } else {
            detailContent
                .transition(.move(edge: .trailing))
        }
    }
    .animation(.easeInOut(duration: 0.22), value: subScreen)
}
```

**Views changed:**
- `SettingsView` — `SettingsSubScreen` drives AddRunner, AddScope, EditScope, EditRunner
- `ScopeDetailView` — `ScopeDetailSubScreen` replaces `showHookSheet` + `showBranchSheet`
- `AddScopeSheet` — `AddScopeSubScreen` replaces `showScopeSelector`

---

## Reference: How Other Statusbar Apps Do It

| App | Window type | Settings | Sheets |
|-----|-------------|----------|--------|
| Bartender 5 | `NSPanel` + `.titled` hidden | Separate `NSWindow` | Works — parent is titled |
| Stats | `NSPanel` borderless | Inline scroll within panel | No sheets |
| Raycast | Single `NSWindow` | Inline navigation | No child windows |
| Hand Mirror | `NSPanel` + `.hudWindow` | Inline preferences | No sheets |
| Lungo | `NSMenu` | Standard `NSWindow` | N/A |

**Key takeaway:** None use `.sheet` inside a borderless `NSPanel`.

---

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-05-29 | Drop SwiftUI `.sheet` everywhere | Fundamentally incompatible with borderless NSPanel |
| 2026-05-29 | All sub-screens pushed inline | Eliminates child window problem at root |
| 2026-05-29 | Keep `PanelChromeView` as-is | Arrow + HUD look works; problem was child windows |
| 2026-05-29 | Do NOT use `masksToBounds = true` | Clips child windows |
| 2026-05-29 | Do NOT use `layer.cornerRadius` on contentView | No-op on transparent surface |
