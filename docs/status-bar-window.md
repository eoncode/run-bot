# Status Bar Window Strategy

> **Last updated:** 2026-05-29  
> **Issue:** #1017 — SettingsView gets rectangular corners when a SwiftUI `.sheet` is presented

---

## The Core Problem

When a SwiftUI `.sheet` (e.g. `RunnerDetailPopover`, `ScopeEditSheet`, `AddRunnerSheet`) is
presented on top of `SettingsView`, the **parent window** — not the sheet — loses its rounded
corners and goes fully rectangular.

This is **not** a bug in RunnerBar's logic. It is a well-known consequence of how AppKit handles
sheet presentation on windows that rely on any form of *custom* corner radius.

### Why it happens

When AppKit calls `window.beginSheet(sheet)` it:
1. Adds the sheet as a child `NSWindow` via `addChildWindow(_:ordered:)` (or the newer
   `NSWindowAttachmentBehavior` path on macOS 14+).
2. To composite the two windows, it modifies the **parent window's `CALayer` tree** — in
   particular the `masksToBounds` and `mask` properties on the content view's backing layer.
3. Any `CAShapeLayer` mask or `cornerRadius + masksToBounds` that *you* set on that layer is
   removed or invalidated by AppKit as a side-effect.

This is documented nowhere publicly, but is confirmed by multiple developer reports:
- https://github.com/eoncode/runner-bar/issues/1017
- https://stackoverflow.com/questions/62995489 (clear bg + borderless doesn't survive sheet)
- Electron issue #9159 (same root cause in a different runtime)

---

## What Has Been Tried and Why It Failed

### Attempt 1 — `CAShapeLayer` mask on `NSVisualEffectView` (original approach, `PanelChromeView`)

**What it did:** Drew a custom Bézier path (rounded rect + arrow tip) as a `CAShapeLayer` and
applied it as `fxView.layer.mask`.  
**Why it failed:** AppKit removes/replaces `layer.mask` on the parent window's content view
when a sheet is attached. The panel body went rectangular immediately on sheet presentation and
stayed rectangular until the sheet was dismissed.

### Attempt 2 — `contentView.layer.cornerRadius + masksToBounds` (PR #1017 first iteration)

**What it did:** Removed `PanelChromeView` and set `cornerRadius` + `masksToBounds` directly on
the `NSHostingController.view` (= the panel's content view layer).  
**Why it failed:** `masksToBounds = true` is precisely what AppKit modifies during sheet
attachment. Same result — corners go rectangular on sheet open. Also: `masksToBounds` clips child
`NSWindow`s' visual content, creating rendering artefacts.

### Attempt 3 — `backgroundColor = .clear + isOpaque = false` ("window-server native corners")

**What it did:** Made the panel fully transparent (no content view layer manipulation), relying
on the window server to draw native rounded corners on a borderless `NSPanel`.  
**Why it failed (observed):**
- The panel background became completely transparent — no glass, no vibrancy, no visual surface.
  `.background(.regularMaterial)` was added to `PanelMainView` in a follow-up commit but still
  did not restore the background.
- Corners **still** went rectangular when a sheet opened.
- **Root cause diagnosis:** A borderless `NSPanel` with `backgroundColor = .clear` does NOT get
  window-server native rounded corners. The "native rounded corners" behaviour only applies to
  windows that have a *standard* (non-borderless) style mask, or that use
  `NSWindow.styleMask = [.titled, .fullSizeContentView]`. A raw `[.borderless]` panel is a plain
  rectangle at the compositor level — no rounding applied by the window server regardless of
  `isOpaque`. The transparency just made the rectangle invisible, creating the illusion of
  rounding in the zero-sheet state, but the issue was never actually fixed.

### Attempt 4 — `.background(.regularMaterial)` on `PanelMainView`

**What it did:** Added `.background(.regularMaterial)` to the root VStack of `PanelMainView` to
restore glass vibrancy after `PanelChromeView` was removed.  
**Why it failed:** The `.regularMaterial` applied correctly but provided no rounding. Because
the window layer has no corner radius, the material renders as a plain rectangle. Also the
attached screenshot shows no visible background at all — the material may require the window's
`contentView` to have `wantsLayer = true` and a non-opaque background to composite correctly.

---

## Root Cause Summary

All attempts share the same flaw: they try to apply corner rounding *inside the window's view
hierarchy*. AppKit deliberately discards or overrides any such in-hierarchy clipping when a
sheet is presented.

**The only correct solution is to never let the parent window's own layers be responsible for
rounding.** Two viable paths exist:

---

## New Strategy: Use `NSPopover` Instead of `NSPanel` for the Main Window

### Why NSPopover is the right answer

`NSPopover` is the standard macOS mechanism for a status-bar panel. It:
- Has **native window-server rounded corners drawn by the compositor**, not by any layer.
- Uses a dedicated `NSPopoverWindowFrame` window class, which the AppKit sheet machinery
  **treats differently** — it does not invalidate the frame window's corners on sheet attachment.
- Automatically gets the correct vibrancy/glass background with zero configuration.
- Does not require any `CAShapeLayer`, `cornerRadius`, `masksToBounds`, or `clear` background.
- The `.sheet` modifier in SwiftUI works correctly against it because AppKit's sheet path for
  `NSPopover`-backed windows preserves the popover chrome.

This is exactly how **every well-maintained macOS status bar app** works:
- **Raycast** — uses `NSPopover` with a custom `NSPopoverBehavior`
- **Proxyman** — uses `NSPopover`
- **Hand Mirror, Lungo, Almighty** — use `NSPopover`
- The canonical Apple tutorial at https://developer.apple.com/tutorials/develop-in-swift/
  uses `NSPopover`
- The `fleetingpixels.com` and `capgemini.github.io` tutorials both use `NSPopover`

The original reason RunnerBar moved to `NSPanel` (#377) was to prevent **lateral panel jumps**
on content-size changes. That concern is legitimate but can be solved within `NSPopover` using:
1. `popover.contentSize` driven by `NSHostingController.preferredContentSize` (same KVO approach
   used today).
2. `popover.positioningRect` re-set on the same `NSStatusBarButton.bounds` each time — the
   popover anchor stays fixed; only the content size changes.

### What needs to change

| Current | Target |
|---|---|
| `KeyablePanel: NSPanel` with `.borderless` style | `NSPopover` with `NSHostingController` |
| Manual `setFrame()` in `resizeAndRepositionPanel()` | `popover.contentSize = controller.preferredContentSize` |
| Custom `panelTopY` anchor tracking | `popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)` |
| `panel.level = .popUpMenu` | Not needed — `NSPopover` handles its own level |
| `eventMonitor` for outside click | `NSPopover.behavior = .transient` handles this |
| Sheet rounding broken | Sheet rounding works natively |
| No glass background | Automatic popover chrome |

### What stays the same

- All SwiftUI views (`PanelMainView`, `SettingsView`, all sheets) — zero changes
- `AppDelegate+Navigation.swift` view factories — zero changes
- `panelVisibilityState` / `PanelVisibilityState` — needs `isOpen` driven from `NSPopoverDelegate`
- `makeKeyForTextInput()` — replaces `panel.makeKeyAndOrderFront(nil)` with `NSApp.activate(ignoringOtherApps: true)`
- `closePanel()` / `hidePanel()` — replaces `panel.orderOut(nil)` with `popover.performClose(nil)`

### Known concern: lateral jumps (#377)

When SwiftUI reports a new `preferredContentSize`, `NSPopover` will briefly jump to the new
size. To mitigate:
- Do NOT animate the popover (`popover.animates = false`).
- Always re-show relative to the same `button.bounds` — the arrow anchor stays fixed.
- The jump is a single-frame reposition, identical to what `NSPanel.setFrame()` currently does.

### Fallback if NSPopover is insufficient

If the `NSPopover` path reintroduces the lateral jump issue intolerably, the second-best option
is to use a **titled, full-size content view `NSPanel`** instead of borderless:

```swift
let newPanel = KeyablePanel(
    contentRect: NSRect(x: 0, y: 0, width: initW, height: 300),
    styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
newPanel.titleVisibility = .hidden
newPanel.titlebarAppearsTransparent = true
newPanel.standardWindowButton(.closeButton)?.isHidden = true
newPanel.standardWindowButton(.miniaturizeButton)?.isHidden = true
newPanel.standardWindowButton(.zoomButton)?.isHidden = true
```

A `.titled + .fullSizeContentView` window **does** get native window-server rounded corners
(because macOS only rounds titled windows). With `titlebarAppearsTransparent + titleVisibility.hidden`
the title bar is invisible but the compositor-level rounding remains. This is how
app like **Tot** and **Pockity** handle it.

---

## Implementation Plan (NSPopover path)

1. **`AppDelegate+PanelSetup.swift`** — replace `KeyablePanel` construction with `NSPopover`
   construction. Set `popover.contentViewController = controller`, `popover.animates = false`,
   `popover.behavior = .applicationDefined`.
2. **`AppDelegate.swift`** — replace `panel: KeyablePanel?` with `popover: NSPopover?`. Replace
   `openPanel()` with `showPopover()`, `closePanel()` with `closePopover()`.
3. **`AppDelegate+Navigation.swift`** — replace `makeKeyForTextInput()` call with
   `NSApp.activate(ignoringOtherApps: true)`.
4. **`KeyablePanel.swift`** — can be deleted or kept for a future fallback.
5. **`resizeAndRepositionPanel()`** — replace `setFrame()` with
   `popover.contentSize = newSize`. No panelTopY, no statusItemRect arithmetic.
6. **`eventMonitor`** — remove entirely (`NSPopover.behavior = .transient` handles outside click).
7. **`workspaceObserver`** — keep, replacing `hidePanel()` with `popover.performClose(nil)`.
8. **`PanelChromeView` / `PanelChrome.swift`** — already removed, leave as tombstone.
9. **`PanelMainView.swift`** — remove `.background(.regularMaterial)` (popover provides chrome).

---

## Session Log — 2026-05-29: Outside-tap + Frozen SettingsView Regressions

After the NSPopover migration landed, two new bugs appeared when tapping outside the app
while a sheet was open.

### Bug A — Main view gray/black flash

**Symptom:** After navigating settings → back → main, the main view flickered gray or black.

**Root cause:** `PanelContainerView` (the sheet-dim overlay) was being instantiated at multiple
levels of the view hierarchy simultaneously. `mainView()` wrapped in it, `settingsView()` wrapped
in it, and `StepLogView` also wrapped in it via `validatedView`. Each instance runs an independent
100ms timer polling `NSPopoverWindowFrame.sheets`. Multiple overlapping `Color.black.opacity(0.35)`
layers animate independently → combined opacity varies → gray/black flicker.

**Fix:** `PanelContainerView` applied only in `mainView()` and `settingsView()`. `StepLogView`
gets no wrapper (it has no sheets).

---

### Bug B — Tapping outside while sheet open: sheet gone, SettingsView frozen on re-open

This is the main regression. Three approaches were tried before finding the correct fix.

#### Attempt B1 — `popoverShouldClose` returns `false` when `hasActiveSheet`

**What it did:** Blocked `NSPopover` from closing at all while a sheet was open.

**Why it failed:** Also blocked outside-tap and workspace app-switch. The user couldn't
interact with any other app while a sheet was open. Rejected.

#### Attempt B2 — Preserve `hostingController.rootView`, restore via `validatedView(.settings)` on re-open

**What it did:** `closePanel()` skipped resetting `hostingController.rootView` when
`savedNavState == .settings`, hoping the existing SwiftUI tree (with sheet `@State` = `true`)
would survive the popover close and be reused on next open. On re-open, `validatedView(.settings)`
called `settingsView()` to navigate.

**Why it failed (two reasons):**
1. `settingsView()` constructs a **brand new `SettingsView` struct**. Swift `@State` lives inside
   the View value type and is reset on every new construction. `showAddScopeSheet`, `editingRunner`,
   `selectedScopeEntry` all reset to `false`/`nil`. Sheet cannot be restored this way — ever.
2. The sheet's `NSWindow` (a child of the popover window added by AppKit during `.sheet`
   presentation) is **not** removed when `performClose()` fires. It becomes an **orphan** — still
   attached to the popover window, still intercepting all mouse events, but with no SwiftUI tree
   driving it. On re-open, SettingsView renders behind the invisible orphan sheet window and
   appears completely frozen.

#### Attempt B3 — Same as B2 but without resetting `rootView` at all

**What it did:** Left `hostingController.rootView` as-is (pointing at the old SettingsView
instance with the old `@State`).

**Why it failed:** The orphaned sheet `NSWindow` from the previous session is still attached
regardless of what `rootView` points to. Hit-testing is blocked. Same freeze.

#### Fix — `dismissSheets()` before `performClose()`

**What it does:** Before calling `performClose(nil)`, call `endSheet(_:)` on every window in
`popoverWindow.sheets`. AppKit synchronously removes each child sheet window from the hierarchy
before the popover closes. No orphan is created.

```swift
private func dismissSheets() {
    guard let win = popover?.contentViewController?.view.window else { return }
    for sheet in win.sheets { win.endSheet(sheet) }
}
// Called at top of both closePanel() and hidePanel().
```

**Result on re-open:** `savedNavState = .settings` navigates back to a fresh `SettingsView`.
Sheet is not re-opened (impossible — `@State` cannot be restored), but SettingsView is fully
interactive. This is the correct and only viable behaviour.

**Invariants (as of B3 — superseded, see below):**
- ❌ NEVER remove `dismissSheets()` from `closePanel()` or `hidePanel()`.
- ❌ NEVER try to restore sheet `@State` across close/open via any mechanism.
- ❌ NEVER leave `performClose()` as the first call without `dismissSheets()` preceding it.

> **⚠️ Update — B3 was also discarded.**
> `dismissSheets()` correctly prevents orphan windows on explicit close, but calling it
> from `hidePanel()` (outside-tap / workspace-switch) **destroys sheet `@State`** — the
> user loses their open sheet on every app-switch. Not acceptable.
>
> **Final fix: `hidePopoverWindowsPreservingSheets()` / `restorePopoverWindowsPreservingSheetsIfNeeded()`**
> — on `hidePanel()`, if a sheet is active, order the popover window out (`orderOut(nil)`) instead
> of calling `performClose()`. On re-open, `orderFront(nil)` restores the same window with the
> sheet fully intact. `closePanel()` (explicit dismiss) never fires while a sheet is open by
> design, so `performClose()` is always safe there.
>
> See `§SheetOrphans` in `ARCHITECTURE.md` for the definitive invariants.

---

## Files Changed in This Branch

| File | Change | Status |
|---|---|---|
| `Panel/PanelChrome.swift` | Emptied (tombstone) | ✅ keep |
| `App/AppDelegate+PanelSetup.swift` | NSPopover migration, `NSPopoverDelegate` conformance | ✅ keep |
| `App/AppDelegate.swift` | NSPopover, `hidePopoverWindowsPreservingSheets()`, closePanel/hidePanel rewrite | ✅ keep |
| `App/AppDelegate+Navigation.swift` | PanelContainerView applied once per view level | ✅ keep |
| `App/PanelSheetState.swift` | New — process-lifetime runner sheet state | ✅ keep |
| `Views/Main/PanelContainerView.swift` | New — dim overlay via 100ms sheet polling | ✅ keep |
| `Views/Settings/SettingsView.swift` | `editingRunner` moved to `PanelSheetState` | ✅ keep |
| `Views/Main/PanelMainView.swift` | Comments condensed, workflow list layout refactored | ✅ keep |

---

## References

- Issue #1017 https://github.com/eoncode/runner-bar/issues/1017
- Issue #377 (original NSPanel migration) https://github.com/eoncode/runner-bar/issues/377
- NSPopover Apple docs https://developer.apple.com/documentation/appkit/nspopover
- NSWindowStyles reference https://lukakerr.github.io/swift/nswindow-styles
- fleetingpixels.com NSPopover tutorial https://fleetingpixels.com/articles/2020/how-to-create-a-mac-menu-bar-app-with-nspopover
- capgemini.github.io Swift + SwiftUI menu bar https://capgemini.github.io/development/macos-development-with-swift/
