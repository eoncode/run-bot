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

## Attempt 3 — #1195 commit 2 (2026-06-08): `beginSheetModal` ← CORRECT DIRECTION, incomplete

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

**Status:** ⚠️ PARTIALLY CORRECT — the `beginSheetModal` approach was right,
but the guard in the event monitor was wrong. The existing `for sheet in
popoverWindow.sheets { if sheet.frame.contains(mouseLoc) }` geometry check
is unreliable because `NSEvent.mouseLocation` is read inside a
`Task { @MainActor }` hop — by execution time the mouse has moved and the
captured coordinates may no longer match the sheet frame. The sheet was
visible in `popoverWindow.sheets` correctly, but the frame check still let
`hidePanel()` fire. Subsequent attempts 4–9 went down a different path
(the `isFilePickerActive` flag) before the real fix was found.

**Known risk at the time:** `beginSheetModal` requires a valid `NSWindow`
reference at call time. We obtain it via `NSApp.keyWindow` with a guard.

---

## Attempt 4 — #1195 commit 3 (2026-06-08): `isFilePickerActive` flag + `popoverShouldClose` guard

**Theory:** `beginSheetModal` (Attempt 3) required a valid `NSWindow` reference at call
time obtained via `NSApp.keyWindow`. In practice the sheet attachment either failed
or the picker still opened free-floating. The new approach adds a boolean flag
`isFilePickerActive` to `AppDelegate`. `ScopeDetailView.openFolderPicker()` sets it
`true` before calling `picker.begin { }` and clears it `false` in the completion
handler. `AppDelegate+PanelSetup.popoverShouldClose(_:)` returns `false` while the
flag is `true`, directly blocking AppKit from dismissing the popover.

**Changes:**
- `AppDelegate.swift`: added `var isFilePickerActive = false` (line 122).
- `AppDelegate+PanelSetup.swift`: `popoverShouldClose` now guards on
  `!isFilePickerActive` and logs when the close is blocked.
- `ScopeDetailView.swift`: `openFolderPicker()` sets/clears the flag around
  `picker.begin { }`.
- Reverted back to plain `picker.begin { }` (free-floating) since the flag
  makes sheet attachment unnecessary.

**Status:** ❌ FAILED — confirmed on device 2026-06-08 15:13 CEST.

**Why it failed:**
`popoverShouldClose(_:)` is **only called when `behavior = .applicationDefined`**.
At the time of this attempt the popover was still set to `.transient` (left
over from Attempt 2). With `.transient`, AppKit never consults the delegate —
it closes the popover directly, bypassing `popoverShouldClose` entirely.
The `isFilePickerActive` flag and the delegate guard were structurally dead
code. The comment in `AppDelegate+PanelSetup.swift` line 48 even stated
"popoverShouldClose always returns true. AppKit is never blocked" — that was
written for the `.transient` world and proved the mechanism was inert.

---

## Attempt 5 — #1195 (2026-06-08 15:18 CEST): `.applicationDefined` + `isFilePickerActive` flag

**Theory:** Attempt 4 had the right mechanism (`isFilePickerActive` flag +
`popoverShouldClose` guard) but the wrong behavior mode. `popoverShouldClose`
is only consulted by AppKit when `behavior = .applicationDefined`. Switching
back to `.applicationDefined` and keeping the flag should finally work:
when the user taps inside the NSOpenPanel, AppKit asks `popoverShouldClose`,
we return `false`, the popover stays open.

**Changes:**
- `AppDelegate+PanelSetup.swift`: `newPopover.behavior = .applicationDefined`
  (was `.transient`). Updated the POPOVER BEHAVIOR comment block to reflect
  the correct reasoning.
- `docs/graveyard.md`: Attempt 4 marked failed with root cause explanation.
- No changes to `ScopeDetailView.swift` or `AppDelegate.swift` — the
  `isFilePickerActive` flag and `popoverShouldClose` guard from Attempt 4
  are correct and remain in place.

**Status:** Built and deployed — **in testing as of 2026-06-08 15:18 CEST**.

**Known risk:** `.applicationDefined` requires the manual NSEvent global
monitor and NSWorkspace observer to handle outside-click-hide and
app-switch-hide. These were restored in Attempt 3/4 and are present.
If they were accidentally removed again, the popover would never close.

---

## Attempt 6 — #1195 (2026-06-08 15:53 CEST): Move `isFilePickerActive = true` before `NSApp.activate`

**Theory:** Attempt 5 had the right mechanism (`.applicationDefined` + `isFilePickerActive` flag +
`workspaceObserver` guard + `outsideClickMonitor` guard) but a subtle ordering bug.
In `openFolderPicker()` the call sequence was:

1. `NSApp.activate(ignoringOtherApps: true)` ← fires `didActivateApplicationNotification` **synchronously on main**
2. `delegate?.isFilePickerActive = true` ← **too late** — observer already ran with flag = false
3. `picker.begin { }` ← panel opens

Because `NSApp.activate` dispatches the workspace notification on `.main` immediately,
the `workspaceObserver` closure ran with `isFilePickerActive == false`, saw `panelIsOpen == true`,
passed both guards, and called `hidePanel()` — collapsing the app before the flag was ever set.
Same race applies to the `outsideClickMonitor` if any click arrives between steps 1 and 2.

**Fix:** Swap the order — set `isFilePickerActive = true` **before** calling `NSApp.activate`.
Now both the workspace notification and any immediate click events see the flag as `true`
and bail out of `hidePanel()` before it runs.

**Changes:**
- `ScopeDetailView.swift` `openFolderPicker()`: moved `delegate?.isFilePickerActive = true`
  to before `NSApp.activate(ignoringOtherApps: true)`. Updated comment to explain why.
- `docs/graveyard.md`: this entry.

**Status:** ❌ FAILED — confirmed on device 2026-06-08 16:04 CEST.

**Why it failed:**
The Swift 6 compiler emitted `warning: main actor-isolated property 'isFilePickerActive'
can not be referenced from a Sendable closure` for both the `outsideClickMonitor` and
`workspaceObserver` closures. These closures are non-isolated `Sendable` contexts;
Swift cannot guarantee they read `isFilePickerActive` on the `@MainActor`. The
ordering fix (set flag before `NSApp.activate`) was correct but irrelevant — the
closures were reading a potentially-stale or un-isolated copy of the property
regardless of when it was set.

---

## Attempt 7 — #1195 (2026-06-08 16:04 CEST): `Task { @MainActor }` hop in both closures

**Theory:** Both `outsideClickMonitor` and `workspaceObserver` closures are
non-isolated `Sendable` contexts. Swift 6 warns that reading `@MainActor`-isolated
properties (`isFilePickerActive`, `panelIsOpen`) from them is unsafe — the value
may be stale or read off the main actor entirely. Wrapping the body of each closure
in `Task { @MainActor [weak self] in ... }` forces evaluation onto the main actor,
ensuring the flag read is sequenced correctly after `isFilePickerActive = true`.

**Changes:**
- `AppDelegate.swift` `openPanel()`: wrapped `outsideClickMonitor` closure body
  in `Task { @MainActor [weak self] in ... }`.
- `AppDelegate.swift` `openPanel()`: wrapped `workspaceObserver` closure body
  in `Task { @MainActor [weak self] in ... }`.
- Both changes eliminate the Swift 6 actor-isolation warnings — build is now
  warning-free for these properties.
- `docs/graveyard.md`: Attempt 6 marked failed with root cause explanation.

**Status:** ❌ FAILED — confirmed on device 2026-06-08 16:21 CEST.

**Why it failed:**
The log for the failing test showed **zero `outsideClickMonitor FIRED` lines**. The monitor
never ran. This is only possible when `behavior = .transient` — AppKit bypasses the global
event monitor entirely and closes the popover internally. `behavior` was set to
`.applicationDefined` once at `setupPanel()` time but not re-asserted before each `show()`.
AppKit latches the behavior at show-time, and if it had reset the value between sessions, all
subsequent opens ran as `.transient`. The `Task { @MainActor }` hops and the `isFilePickerActive`
flag were correct but structurally unreachable — the monitor never delivered events to check.

**Known risk:** `Task { @MainActor }` schedules asynchronously on the main actor
cooperative queue. If a click arrives and the task hasn't run yet, `isFilePickerActive`
may still read `false` in a pathological timing window. This is extremely unlikely
since `isFilePickerActive = true` is set synchronously on main before the picker
opens — but if it recurs, the next step is `@MainActor` annotation on the closures
directly or moving to `DispatchQueue.main.sync`.

---

## Attempt 8 — #1195 (2026-06-08 16:22 CEST): Re-assert `behavior` + `delegate` immediately before `popover.show()`

**Theory:** Attempt 7 had the right structure — `.applicationDefined` + `isFilePickerActive` flag +
`Task { @MainActor }` hops in both closures — but the log for the failing test run revealed
that **`outsideClickMonitor` never fired at all**. Zero instances. This is only possible if
`behavior` was not `.applicationDefined` at show-time. When `behavior = .transient`, AppKit
dismisses the popover directly without ever invoking the global monitor or `popoverShouldClose`.
The value was being set once at `setupPanel()` (launch), but AppKit latches `behavior` at
`popover.show()` time — exactly the same rule that already applied to `shouldHideAnchor`,
which the existing code comments explicitly note must be set immediately before `show()`.
`behavior` was never being re-asserted, so if AppKit reset it between sessions it would
silently revert to `.transient` on the next open.

**Fix:** In `AppDelegate.swift openPanel()`, re-assert `popover.behavior = .applicationDefined`
and `popover.delegate = self` immediately before `popover.show()`, alongside `shouldHideAnchor`.
Added PRE-SHOW and POST-SHOW log lines confirming the `behavior.rawValue` on every open.

**Also added:**
- `hidePanel` now logs its caller frame (`Thread.callStackSymbols[1]`) so unexpected dismisses
  are traceable.
- `popoverDidClose` now logs a 5-frame stack and the `behavior.rawValue` at dismiss time, so
  if AppKit still bypasses the delegate the exact call site is visible.

**Changes:**
- `AppDelegate.swift` `openPanel()`: `popover.behavior = .applicationDefined` + `popover.delegate = self`
  re-asserted immediately before `popover.show()`. PRE-SHOW / POST-SHOW log lines added.
- `AppDelegate.swift` `hidePanel()`: added `caller=` to log line.
- `AppDelegate+PanelSetup.swift` `popoverDidClose`: log now emits 5-frame stack + `behavior.rawValue`.

**Status:** In testing as of 2026-06-08 16:22 CEST.

**Known risk:** If AppKit resets `behavior` *during* the `show()` call itself this won't help.
But given the existing `shouldHideAnchor` pattern already works with a pre-show set, the
same approach should work for `behavior`.

---

---

## Attempt 9 — #1195 (2026-06-08 ~16:46 CEST): `AddRunnerSheet.pickExistingFolder()` missing `isFilePickerActive` + using `runModal()`

**Root cause:** The fix so far (`isFilePickerActive` flag + `.applicationDefined` + `Task { @MainActor }` hops)
was only applied to `ScopeDetailView.openFolderPicker()`. A **second, entirely separate** NSOpenPanel
code path existed in `AddRunnerSheet.pickExistingFolder()` that was never updated. This path:
1. Used `NSApp.keyWindow ?? NSApp.mainWindow` to find a window — which can be `nil` when the Settings
   sheet already has focus, since the popover window may not be key at that moment.
2. Fell back to `openPanel.runModal()` when no window was found — opening NSOpenPanel as a
   **free-floating modal** completely outside the popover window hierarchy.
3. Never set `isFilePickerActive = true` at all — so even the `NSApp.keyWindow` path offered
   no protection against `outsideClickMonitor` or `workspaceObserver` calling `hidePanel()`.

This is the panel visible in the screenshot from the bug report (the `actions-runner` folder picker
opened by the "Add pre-existing runner" flow, which uses `AddRunnerSheet` not `ScopeDetailView`).

**Why `runModal()` is fatal:**
`runModal()` opens NSOpenPanel as a free-floating system window. It does NOT appear in
`popoverWindow.sheets`, is NOT a child of any app window, and does NOT appear in `NSApp.windows`.
The `outsideClickMonitor` fires on every click anywhere outside the popover frame — including
inside the runModal panel — and calls `hidePanel()`, collapsing the entire app.

**Fix applied:**
- `AddRunnerSheet.pickExistingFolder()` rewritten to:
  1. Obtain the window via `delegate?.popover?.contentViewController?.view.window` (the popover's
     own backing window — same source used by `ScopeDetailView` via `WindowGrabber`).
  2. Guard-return if window is nil (log + abort rather than silent `runModal()` fallback).
  3. Set `delegate?.isFilePickerActive = true` BEFORE calling `beginSheetModal`.
  4. Call `openPanel.beginSheetModal(for: window)` — attaches the picker as a child sheet.
  5. Clear `delegate?.isFilePickerActive = false` in the completion handler.
- Dense `log()` calls added to the new path so the picker lifecycle is visible in console.

**❌ NEVER use `runModal()` for NSOpenPanel in this app.**
**❌ NEVER use `NSApp.keyWindow ?? NSApp.mainWindow` without also setting `isFilePickerActive`.**
**❌ NEVER add a second NSOpenPanel call site without applying the full flag + sheet pattern.**

**Status:** ❌ FAILED — confirmed on device 2026-06-08 ~18:00 CEST.

**Why it failed:**
The `isFilePickerActive` flag mechanism was the wrong abstraction. The flag
had to be set in calling code, was easy to forget (as Attempt 9 proved —
a second call site was missed entirely), and created a timing dependency
between the flag write and the observer firing. None of these problems
exist with the final fix.

---

## ✅ Attempt 10 — #1195 (2026-06-08 ~18:10 CEST): `guard !self.hasActiveSheet` — FIXED

**Theory:** Strip out the entire `isFilePickerActive` abstraction and replace
it with a direct structural check: if `popoverWindow.sheets` is non-empty,
a sheet is open and no outside click can be genuine. The check has zero
timing dependency, requires no flag management in calling code, and is
automatically correct for every sheet type — NSOpenPanel via
`beginSheetModal`, SwiftUI `.sheet()`, and any future modal.

**Root cause of all previous failures:**
Every attempt from 4–9 tried to suppress `hidePanel()` using a boolean
flag (`isFilePickerActive`) read inside the event monitor or workspace
observer. The flag approach failed for compounding reasons:
- Call sites had to remember to set/clear it (Attempt 9 missed `AddRunnerSheet`).
- Swift 6 actor isolation made reading it safely require `Task { @MainActor }`
  hops (Attempt 7), which introduced new timing windows.
- The `outsideClickMonitor` was already checking `popoverWindow.sheets` but
  only used it for a per-frame `contains(mouseLoc)` geometry test. That test
  was unreliable because `NSEvent.mouseLocation` was captured inside the
  async Task hop, not at monitor-fire time — so coordinates were stale.

**The actual fix (two lines changed):**

In `outsideClickMonitor` inside `AppDelegate.swift openPanel()`:

```swift
// ✅ NEW: if any sheet is attached, skip dismissal entirely.
guard !self.hasActiveSheet else {
    log("AppDelegate › outsideClickMonitor — guard exit: hasActiveSheet=true, skipping hidePanel")
    return
}
// ❌ REMOVED: the per-sheet frame.contains(mouseLoc) loop that was
//    unreliable due to stale mouseLocation inside the Task hop.
```

`hasActiveSheet` is a computed property: `popover?.contentViewController?.view.window?.sheets.isEmpty == false`.
No flag. No timing. No per-call-site boilerplate. If a sheet is open, the
monitor returns immediately. If no sheet is open, normal outside-click
dismissal proceeds unchanged.

**What `beginSheetModal` gives us:**
`beginSheetModal(for: popoverWindow)` attaches NSOpenPanel as a child of
the popover's own `NSWindow`. This makes it appear in `popoverWindow.sheets`
which is exactly what `hasActiveSheet` checks. This was already the correct
APIcall from Attempt 3 — the sheet attachment was always working. Only the
check for it was wrong.

**Changes:**
- `AppDelegate.swift` `openPanel()` `outsideClickMonitor`: added
  `guard !self.hasActiveSheet` before the geometry check; removed the
  `for sheet in popoverWindow.sheets { frame.contains(mouseLoc) }` loop.
- `AppDelegate+PanelSetup.swift`: rewrote the POPOVER BEHAVIOR comment block
  to accurately describe the working mechanism.
- `AppDelegate+PanelSetup.swift` `popoverShouldClose`: updated doc comment
  to reflect it is no longer a control point.
- `AppDelegate.swift`: removed stale `isFilePickerActive` property comment.
- `Resources/Info.plist`: build number bumped to 10.

**Confirmed working:** 2026-06-08 18:19 CEST, build 10.

**Rules going forward:**
- ✅ ALWAYS use `picker.beginSheetModal(for: popoverWindow)` for NSOpenPanel.
- ✅ ALWAYS rely on `hasActiveSheet` — never add per-picker boolean flags.
- ❌ NEVER use `picker.begin { }` (free-floating, invisible to sheets check).
- ❌ NEVER use `runModal()` (same reason).
- ❌ NEVER add an `isFilePickerActive`-style flag — it will be missed somewhere.

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
