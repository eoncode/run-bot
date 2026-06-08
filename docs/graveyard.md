# NSOpenPanel / Popover Dismiss — Fix Graveyard

This document records every approach attempted to fix the bug where the
popover dismisses when the user clicks inside the NSOpenPanel file picker
(issue #1193). Each entry documents what was tried, the theory behind it,
and exactly why it failed.

---

## Bug Summary

**Flow:** NSPopover → SwiftUI SettingsView → `.sheet` → ScopeEditSheet →
"Browse for folder" button → `openFolderPicker()` → NSOpenPanel.

**Symptom:** Clicking inside the NSOpenPanel file picker in any area that
falls outside the popover's frame causes the popover (and the sheet) to
dismiss immediately.

**Affected versions:** Introduced in or around the week of 2026-06-01.
Used to work before that.

---

## Attempt 1 — #1186 (2026-06-07): `NSApp.modalWindow` + `NSApp.windows` guards

**Theory:** The global mouse-event monitor calls `hidePanel()` when a click
lands outside the popover frame. Adding guards for `NSApp.modalWindow != nil`
(covers NSOpenPanel modal sessions) and `NSApp.windows.contains { $0.frame.contains(screenLoc) }`
(covers other app-owned windows) should catch the NSOpenPanel click.

**What happened:** Did not fix the bug.

**Why it failed:**
- `picker.begin { }` is asynchronous and free-floating. It never starts a
  modal run loop, so `NSApp.modalWindow` is always `nil` while the picker
  is open. The modal guard is permanently inactive.
- `NSApp.windows` only contains windows created directly by the app.
  `NSOpenPanel` is a system-managed window and never appears in that array.
  So the `inOtherAppWindow` guard is also permanently inactive.
- Both guards are structurally blind to this specific NSOpenPanel usage.

---

## Attempt 2 — #1195 commit 1 (2026-06-08): Switch to `.transient` behavior

**Theory:** `NSPopover.behavior = .transient` hands dismiss control to
AppKit natively. The assumption was that AppKit's native dismiss logic
would be aware of system panels (NSOpenPanel) spawned by the app and
not dismiss the popover while they are active — since AppKit owns both.

**Also removed:** The entire manual `NSEvent` global monitor and
`NSWorkspace` observer, since `.transient` was expected to replace both.

**What happened:** Tested on device — **did not fix the bug**. The popover
still dismissed on every click inside the file picker.

**Why it failed:**
- Apple's documentation for `.transient` states: *"The system will close
  the popover when the user interacts with user interface elements in the
  window containing the popover's positioning view."*
- For a menu bar app the popover's positioning view lives in the status bar
  button's window (or effectively no regular window at all). `.transient`
  has no special awareness of NSOpenPanel — it just closes on any outside
  interaction, full stop.
- The assumption that AppKit would "know" about its own NSOpenPanel was wrong.

---

## Attempt 3 — #1195 commit 2 (2026-06-08): `beginSheetModal` ← CURRENT

**Theory:** The real problem is that `picker.begin { }` opens NSOpenPanel
as a free-floating window that is invisible to every inspection mechanism
we have. If we instead attach NSOpenPanel as a sheet to the popover's own
backing window using `picker.beginSheetModal(for: popoverWindow)`, it
appears in `popoverWindow.sheets`. The event monitor already has a working
`inSheet` guard that checks `popoverWindow.sheets` — so no monitor changes
are needed at all.

**Changes:**
- `AppDelegate+PanelSetup.swift`: reverted back to `.applicationDefined`.
- `AppDelegate.swift`: full event monitor and workspace observer restored,
  with dense logging added throughout so the dismiss decision is visible
  in the console on every click.
- `ScopeDetailView.swift`: `openFolderPicker()` switches from
  `picker.begin { }` to `picker.beginSheetModal(for: popoverWindow)`,
  attaching the picker as a sheet to the popover window.

**Status:** In testing.

**Known risk:** `beginSheetModal` requires a valid `NSWindow` reference at
call time. We obtain it via `NSApp.keyWindow` (the popover is key when the
button is tapped) with a guard so we fall back to `begin { }` if the window
is unexpectedly nil — preserving the old behaviour rather than silently
doing nothing.

---

## Reading list / references

- https://ohanaware.com/swift/macOSOpenPanelSheet.html — documents the
  `beginSheetModal` approach for SwiftUI macOS sheet + open panel
- https://gist.github.com/bardigolriz/aa1f58b4e235cb5ea7b89afaa9977f89 —
  event monitor pattern for `.applicationDefined` menu bar popovers
- Apple docs: NSPopover.Behavior.transient — confirms .transient scope is
  limited to the window containing the positioning view
- Issue #1193 — original bug report with screenshot
- Issue #1195 — root cause analysis and fix tracking
