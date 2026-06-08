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

## Attempt 3 — #1195 commit 2 (2026-06-08): `beginSheetModal` with `NSApp.keyWindow`

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

**Status:** ❌ FAILED.

**Why it failed:**
`beginSheetModal` requires a valid `NSWindow` reference at call time.
The window was obtained via `NSApp.keyWindow` at the moment the folder
button was tapped. In practice the SwiftUI sheet's presentation mechanics
cause the popover's backing window to resign key status briefly before the
tap handler fires — so `NSApp.keyWindow` was `nil` and the picker fell back
to `picker.begin {}`, reproducing the original bug.

---

## Attempt 4 — #1195 commit 3 (2026-06-08): `isFilePickerActive` flag + `popoverShouldClose` guard

**Theory:** `beginSheetModal` (Attempt 3) required a valid `NSWindow` reference at call
time obtained via `NSApp.keyWindow`. In practice the sheet attachment either failed
or the picker still opened free-floating. The new approach adds a boolean flag
`isFilePickerActive` to `AppDelegate`. `ScopeDetailView.openFolderPicker()` sets it
`true` before calling `picker.begin { }` and clears it `false` in the completion
handler. `AppDelegate+PanelSetup.popoverShouldClose(_:)` returns `false` while the
flag is `true`, directly blocking AppKit from dismissing the popover.

**Status:** ❌ FAILED — confirmed on device 2026-06-08 15:13 CEST.

**Why it failed:**
`popoverShouldClose(_:)` is **only called when `behavior = .applicationDefined`**.
At the time of this attempt the popover was still set to `.transient` (left
over from Attempt 2). With `.transient`, AppKit never consults the delegate —
it closes the popover directly, bypassing `popoverShouldClose` entirely.

---

## Attempt 5 — #1195 (2026-06-08 15:18 CEST): `.applicationDefined` + `isFilePickerActive` flag

**Theory:** Attempt 4 had the right mechanism (`isFilePickerActive` flag +
`popoverShouldClose` guard) but the wrong behavior mode. `popoverShouldClose`
is only consulted by AppKit when `behavior = .applicationDefined`. Switching
back to `.applicationDefined` and keeping the flag should finally work.

**Status:** ❌ FAILED — confirmed on device 2026-06-08 CEST.

**Why it failed:**
A separate resign-active path — not guarded by `isFilePickerActive` — was
firing. `picker.begin {}` opens NSOpenPanel in an XPC service process
(`com.apple.appkit.xpc.openAndSavePanelService`). When that process becomes
frontmost, macOS sends `NSApplicationDidResignActiveNotification` to
RunnerBar. An unguarded `applicationWillResignActive` / resign-active
observer called `NSApp.hide()` (not `hidePanel()`), collapsing the entire
app to the Dock — bypassing `popoverShouldClose` entirely.

---

## Attempt 6 — #1195 (2026-06-08 15:53 CEST): Move `isFilePickerActive = true` before `NSApp.activate`

**Theory:** The ordering race where `NSApp.activate` fired the workspace
observer before the flag was set.

**Status:** ❌ FAILED — confirmed on device 2026-06-08 16:xx CEST.

**Why it failed:**
Log analysis showed no `outsideClickMonitor`, `workspaceObserver`, or
`hidePanel` log lines firing at dismiss time — only `LocalRunnerStore.runners
fired` and `RunnerViewModel reload`. The dismiss was coming from
`NSApplicationDidResignActiveNotification` (resign-active), not from any
monitor or workspace path. Moving the flag earlier had zero effect because
the resign-active handler was never guarded by `isFilePickerActive` at all.
The entire `isFilePickerActive` mechanism was defending the wrong code path.

---

## Attempt 7 — fix/1193-window-grabber-open-panel (2026-06-08 16:18 CEST): `WindowGrabber` + `beginSheetModal` ← CURRENT

**Theory:** All previous attempts tried to guard around the side-effects of
`picker.begin {}` opening NSOpenPanel in a foreign XPC process. The correct
fix is to never open a foreign XPC window in the first place.

`picker.beginSheetModal(for: window)` attaches NSOpenPanel as a sheet on
the popover's own backing `NSWindow`. The panel runs in-process, inside
the app's window hierarchy. macOS never transfers app-activation to a
foreign process, so `NSApplicationDidResignActiveNotification` is never
fired for the picker — the app-hide path is never triggered.

Attempt 3 tried `beginSheetModal` but failed because it obtained the window
via `NSApp.keyWindow` at button-tap time, which was nil. The fix is to use
`WindowGrabber` — an `NSViewRepresentable` that captures the backing
`NSWindow` via `viewDidMoveToWindow()` at view-mount time, before any user
interaction. The reference is stored in `@State var hostWindow` and is
always valid when `openFolderPicker()` is called.

**Changes:**
- `Sources/RunnerBar/App/NSWindowGrabber.swift` — new file. `NSWindowGrabber`
  is an `NSView` subclass that calls a closure from `viewDidMoveToWindow`.
  `WindowGrabber` is the SwiftUI `NSViewRepresentable` wrapper.
- `ScopeDetailView.swift`:
  - `@State var hostWindow: NSWindow?` added.
  - `.background(WindowGrabber { hostWindow = $0 })` added to `body`.
  - `openFolderPicker()` calls `picker.beginSheetModal(for: hostWindow)`
    with `picker.begin {}` as a nil-fallback.
  - `NSApp.activate(ignoringOtherApps: true)` removed entirely.
- `docs/graveyard.md`: this entry.
- `AppDelegate.swift` / `AppDelegate+PanelSetup.swift`: **no changes**.
  `isFilePickerActive` and all existing guards remain as a safety net.

**Status:** In testing as of 2026-06-08 16:18 CEST.

**Known risks:**
- If the SwiftUI sheet is presented in a detached window context where
  `viewDidMoveToWindow` fires with a transient window, `hostWindow` could
  point to a window that is later deallocated. In practice this does not
  happen for `NSPopover`-hosted SwiftUI content.
- `beginSheetModal` requires the target window to be visible and on-screen.
  Since `openFolderPicker()` is only callable while the sheet is presented
  (and therefore the popover is open), this is always satisfied.

---

## Reading list / references

- https://ohanaware.com/swift/macOSOpenPanelSheet.html — WindowGrabber +
  beginSheetModal pattern for SwiftUI macOS sheet + open panel
- https://gist.github.com/bardigolriz/aa1f58b4e235cb5ea7b89afaa9977f89 —
  event monitor pattern for `.applicationDefined` menu bar popovers
- Apple docs: NSPopover.Behavior.transient — confirms .transient scope is
  limited to the window containing the positioning view
- Issue #1193 — original bug report with screenshot
- Issue #1195 — root cause analysis and fix tracking (Attempts 1–6, now closed)
