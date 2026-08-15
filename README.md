# macOS Animation Fix

A tiny macOS menu bar utility that works around a macOS UI animation
stuttering issue by keeping a minimal display-capture session active.

The default build uses the legacy CoreGraphics `CGDisplayStream` API — the
same effect as ScreenCaptureKit, but with no `replayd` daemon in the loop.
An officially supported ScreenCaptureKit variant (`main-sck.swift`) ships
alongside it and is one build flag away (`./build.sh sck`).

## The problem

On some Macs running macOS 26/27, UI animations can become noticeably
stuttery when the system is otherwise idle.

For example:

- Finder Quick Look animations can have very poor frame pacing.
- Normal window animations may stutter.
- The GPU can be nearly idle while the UI is visibly dropping frames.
- Increasing GPU workload does not necessarily fix the problem.

Interestingly, starting screen recording can make the animations immediately
smooth again.

This project explores and provides a lightweight way of reproducing that effect
without actually recording or processing the screen.

## Current workaround (default: CGDisplayStream)

The default build starts a minimal legacy `CGDisplayStream` session, driven
directly by the WindowServer display-capture pipeline — no `replayd` daemon
is involved:

- 64 × 36 capture resolution
- 1 FPS
- no cursor
- frames delivered to the app via IOSurface are ignored (nothing is buffered,
  encoded, logged, or stored)

The session is simply kept active.

Despite the extremely small capture configuration, keeping it running
restores smooth UI animations — **buttery smooth** on macOS 26/27.

This is a significant narrowing of the mechanism: the smoothing effect does
**not** require ScreenCaptureKit or `replayd`.  An active display-capture
session at the WindowServer level is sufficient — provided the pipeline is
actually delivering frames (see the zero-rate test below, which stutters).

Notes:

- `CGDisplayStream` is marked obsolete in the macOS 15+ SDK.  `build.sh`
  compiles it with a macOS 14 deployment target so the symbols remain
  callable; they still exist at runtime on macOS 26/27 — verified.  If a
  future macOS removes them, switch to the SCK variant: `./build.sh sck`.
- Unlike the SCK variant, `CGDisplayStream` captures the whole display (no
  window exclusion), downscaled to 64 × 36 at 1 FPS.

### ScreenCaptureKit variant (the supported fallback)

`main-sck.swift` (built with `./build.sh sck` → `AnimationFixSck.app`) is the
same menu-bar app with the capture session implemented as a ScreenCaptureKit
`SCStream` instead of the legacy API.  It routes the session through the
`replayd` daemon and supports window exclusion and an explicit
`SCStreamOutput` (both omitted in this build — frames are never delivered).

The result is identical: with an `SCStream` session active at 64 × 36, 1 FPS,
UI animations are **buttery smooth**.  This is the officially supported API,
so it is the fallback if a future macOS ever removes the obsoleted
`CGDisplayStream` symbols:

```bash
./build.sh sck run     # or: ./build.sh sck install
```

## Experimental observation

The behavior was isolated through the following tests:

| Test | Result |
|---|---|
| Normal idle GPU | UI stutters |
| Artificial Metal GPU workload | UI still stutters |
| Screen recording | UI becomes smooth |
| Screenshot | UI becomes smooth temporarily |
| `SCStream` + frame output | UI becomes smooth |
| `SCStream` without `SCStreamOutput` | UI becomes smooth |
| Creating `SCStream` without `startCapture()` | UI stutters |
| `SCStream.startCapture()` | UI becomes smooth |
| `CGDisplayStream` (CoreGraphics, no replayd) | UI becomes smooth |
| `CGDisplayStream` zero-rate (min frame time 1e9 s → no frames delivered) | UI stutters |
| `CGDisplayStream` without `start()` (no capture session) | UI stutters |

The important observation is that **starting the capture session itself appears to
be sufficient**. The application does not need to consume the captured frames.

A zero-rate `CGDisplayStream` test narrows this further: with
`minimumFrameTime` set to ~1e9 seconds (session active, but the pipeline is
asked to never deliver a frame), UI animations **stutter again**.  So an
active session alone is not enough — the display-capture pipeline must
actually be **producing frames** at some rate for the effect to kick in,
even though the app ignores every frame it receives.

The no-`start()` control — stream object created but never started, so no
capture session exists at all — also stutters, confirming the stream must
actually be running for the effect to appear.

This suggests that the effect is related to a system-level display/compositor
state rather than simply increased GPU utilization, and that the relevant
state lives in the WindowServer display-capture/compositor pipeline itself
(no ScreenCaptureKit, no `replayd` required).

## Building

### Requirements

- macOS 26 or later
- Apple Silicon Mac
- Xcode Command Line Tools
- Screen Recording permission

You do **not** need the full Xcode application. The Xcode Command Line Tools
are sufficient to compile the project.

Two variants are built by the same script.  The default is the
`CGDisplayStream` build (`main.swift` → `AnimationFix.app`); the
ScreenCaptureKit build is one argument away (`main-sck.swift` →
`AnimationFixSck.app`):

```bash
./build.sh run        # default (CGDisplayStream, no replayd)
./build.sh sck run    # ScreenCaptureKit (supported fallback)
```

### 1. Clone the repository

```bash
git clone https://github.com/seakrebel/macos-animation-fix.git
cd macos-animation-fix
```

### 2. Build and run

The build is a single command — the `build.sh` script compiles `main.swift`,
assembles `AnimationFix.app` and writes its `Info.plist`:

```bash
./build.sh
```

Useful variants:

```bash
./build.sh run       # build and run from the terminal (shows the app's log)
./build.sh install   # build, install to /Applications, and launch it
```

The script is a thin wrapper around `swiftc` (the default build links
AppKit, CoreGraphics, CoreVideo and IOSurface; the SCK build links AppKit,
ScreenCaptureKit and CoreMedia), bundle assembly, and a minimal
`Info.plist` with `LSUIElement` — see `build.sh` for the exact steps.

## Keeping the session alive

Capture sessions are invalidated by the system whenever the display
environment changes:

- the Mac sleeps or wakes (including closing / opening the lid),
- the screen is locked or unlocked,
- displays are connected or disconnected (e.g. a docking station),
- a display wakes from display sleep.

Both variants watch for these events and automatically recreate the
capture session:

- `NSWorkspace.didWakeNotification` / `screensDidWakeNotification` (sleep/wake)
- `NSWorkspace.sessionDidBecomeActiveNotification` (unlock)
- `NSApplication.didChangeScreenParametersNotification` (dock, external displays)

A watchdog restarts the session if the system kills it for any other
reason — the CG build detects an unexpected `.stopped` status in its frame
handler, the SCK build implements
`SCStreamDelegate.stream(_:didStopWithError:)`.  Restarts are
debounced (dock transitions fire a burst of notifications) and transient
start failures right after wake are retried automatically.

### Verifying

Run `./build.sh run` (builds and runs from the terminal so you can see its
output):

```bash
./build.sh run
```

Trigger each scenario and confirm the log ends in `capture ACTIVE`:

| Scenario | Expected log |
|---|---|
| Lock, then unlock the screen | `stream stopped unexpectedly` → `capture ACTIVE` |
| Sleep (`pmset sleepnow` or close the lid), then wake | `environment changed: ...` → `capture ACTIVE` |
| Attach/detach a docking station or external display | `environment changed: ...` → `capture ACTIVE` |
| Disable via the menu, then re-enable | `capture STOPPED` → `capture ACTIVE` |

Note: replacing the binary can reset the Screen Recording grant.  If the log
shows a permission error, re-grant it in System Settings → Privacy & Security
→ Screen Recording, then relaunch.

## Security

There are no known security vulnerabilities in this codebase.  The attack
surface is deliberately minimal and the entire implementation is auditable.

**The app never uses your screen content.**  The SCK build creates the
`SCStream` without an `SCStreamOutput`, so frames are never delivered to the
process.  The default CG build's frame handler is a no-op that discards
every IOSurface immediately.  In both builds, frames are not buffered,
encoded, logged, or stored anywhere.  The app's only effect is keeping the
capture *session* active.

**No other sensitive access:**

- no network access (no sockets, HTTP, or IPC),
- no file or disk writes,
- no user input or untrusted data is ever parsed,
- no shell or process spawning,
- no persistent storage (`UserDefaults`, keychain, or config files),
- no accessibility or keyboard APIs,
- no dependencies — a single Swift file using only Apple frameworks.

**Capture scope is minimal:**

- one display (`displays.first`), on-screen windows only,
- 64 × 36 at 1 FPS,
- no audio (`capturesAudio = false`),
- no cursor (`showsCursor = false`).

**Transparency:**

- The whole implementation is two Swift files in this repository
  (`main.swift` — the default build — and `main-sck.swift`).  Build it from
  source and audit it yourself; do not run prebuilt binaries from
  untrusted sources.
- While the stream is active, macOS shows its own screen-recording
  indicator in the menu bar, independently of this app.

**What you should understand:** the app holds Screen Recording permission,
which is inherent to its purpose — macOS treats starting a display-capture
session (either variant) as screen recording.  As with any recording app, a
modified build would have access to the screen, and the binary itself is
ad-hoc signed and not sandboxed.  For the code in this repository that is
irrelevant (it does nothing but start a capture session), but it is why you
should always build and run the app from the published source.

## Important disclaimer

This is an experimental workaround.

It does **not** prove that the underlying macOS bug is specifically a
"Metal compositor" bug or that `WindowServer` is definitely switching to a
particular internal rendering path.

The exact mechanism is currently unknown.

The project is based on observed behavior:

```text
No active display-capture session
    ↓
UI animations stutter

Display-capture session whose frames are actually flowing
(`SCStream` via replayd, or `CGDisplayStream` directly)
    ↓
UI animations become smooth
```

