# Permission Status Not Updating Live — Diagnosis & Plan

## Symptom

In the Voice Settings window, toggling **Microphone** or **Accessibility** for Voice in
System Settings while the window is open does NOT update the status row. It keeps showing
"Granted". Closing and reopening the window updates it.

## Root cause (two compounding layers, found via research)

### 1. PRIMARY — `swift run` has the wrong TCC identity (this is the real blocker)

- `swift run` produces a bare `.build/debug/voice` Mach-O: no `.app` bundle, no embedded
  `Info.plist`, ad-hoc signed with a cdhash that changes on every build.
- macOS TCC attributes permissions through an **attribution chain to a "responsible
  process."** For a terminal-launched binary, the responsible app is the **Terminal/IDE**,
  not "Voice."
- Therefore the **"Voice" row toggled in System Settings is the installed cask `Voice.app`**
  (`dev.rafaelbm.voice`), a *different TCC identity* than the running dev binary. Toggling
  it cannot affect the running process — no code change could detect it.

**Consequence:** this feature CANNOT be validated under `swift run`. Must test a real,
stably-signed `.app` launched from Finder/`open`.

### 2. SECONDARY — every trust-check API is per-process cached

- `AXIsProcessTrusted()`, `CGPreflightListenEventAccess()`, `IOHIDCheckAccess(...)`, and
  `AVCaptureDevice.authorizationStatus(for:)` all read a process-local cache that `tccd`
  never invalidates at runtime.
- **The `CGEvent.tapCreate(.listenOnly)` "live probe" we added is NOT live.** Once a tap
  succeeds in a process it keeps succeeding after revocation (it degrades silently to
  `tapDisabledByTimeout`, it does not return nil). The probe gives false confidence and
  should be removed.
- There is **no public API** that reports live permission changes in-process. Apple's model
  assumes relaunch. (ES `TCC_MODIFY` exists in macOS 15.4+ but needs root + ES entitlement.)

## What shipping apps actually do (AltTab, Rectangle, node-mac-permissions)

Nobody gets a true "live event." The working patterns are:

- **Refresh on app re-activation** — re-read status on `NSApplication.didBecomeActiveNotification`
  and on window/popover focus. Covers the dominant UX (toggle in Settings → switch back to app),
  usually within ~1s. This is the de-facto solution.
- **Throttled poll while the settings window is visible** — `AXIsProcessTrusted()` every
  ~0.3–1s. Reliably live for *grants*; can be stale for some *revoke* paths.
- **Microphone revoke is self-correcting** — macOS kills/relaunches an app when its mic/camera
  grant changes, so the next read after restart is fresh.
- Run system checks **off the main thread with a timeout** — these calls can hang during a
  revoke (AltTab wraps them in a 6s timeout).

## Plan

### A. Fix the dev/test methodology (the actual fix for "it doesn't work")
1. Add a `scripts/run-app.sh` (or document) that does: `swift build` → package `.build/debug/voice`
   into a real `Voice.app` (embed `Resources/Info.plist` as `Contents/Info.plist`, binary at
   `Contents/MacOS/voice`) → sign with a **stable** identity (Apple Development cert, or a
   persistent self-signed cert — NOT ad-hoc `-`) → `open Voice.app`.
2. Use a **distinct dev bundle id** (e.g. `dev.rafaelbm.voice.debug`) OR uninstall the cask app
   during dev, so the dev app gets its OWN TCC row and the toggle maps to the running process.
3. On signature change, clear stale grants: `tccutil reset Accessibility <id>` /
   `tccutil reset Microphone <id>` (app already resets Accessibility).

### B. Replace the false "live probe" with patterns that work (code)
1. **Remove** `liveAccessibilityTrusted()`'s create-and-tear-down tap; revert Accessibility to
   `AXIsProcessTrusted()` (honest cached read).
2. **Add refresh on re-activation:** observe `NSApplication.didBecomeActiveNotification` (and
   window-key) → `refreshPermissions()`. This is the primary live-feeling trigger.
3. **Keep** the windowed 1s poll for grant-detection (already added). Run the snapshot work off
   the main thread if it ever hangs.
4. **Microphone:** keep cached `authorizationStatus`; rely on OS-restart-on-revoke + reactivation
   re-read. Keep the "relaunch to refresh" caption. Use `requestAccess` only when `.notDetermined`.

## Verification (MUST use a bundled, signed .app — not `swift run`)
1. Build + sign + `open Voice.app` from Finder with its own dev bundle id.
2. Grant Accessibility → row shows Granted.
3. With the window open, revoke in System Settings, switch back to Voice → row flips to Missing
   on reactivation (and within ~1s via poll for the manual-toggle path).
4. Microphone: revoke → app is restarted by macOS → row reads fresh on relaunch.
