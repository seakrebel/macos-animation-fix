# macOS Animation Fix

A tiny macOS menu bar utility that works around a macOS UI animation
stuttering issue by keeping a minimal ScreenCaptureKit capture session active.

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

## Current workaround

The application starts a minimal `ScreenCaptureKit` `SCStream`:

- 64 × 36 capture resolution
- 1 FPS
- no audio
- no cursor
- no `SCStreamOutput`
- captured frames are not processed or encoded

The stream is simply kept active.

Despite the extremely small capture configuration, starting the stream can
restore smooth UI animations.

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

The important observation is that **starting the capture session itself appears to
be sufficient**. The application does not need to consume the captured frames.

This suggests that the effect is related to a system-level display/compositor
state rather than simply increased GPU utilization.

## Building

### Requirements

- macOS 26 or later
- Apple Silicon Mac
- Xcode Command Line Tools
- Screen Recording permission

You do **not** need the full Xcode application. The Xcode Command Line Tools
are sufficient to compile the project.

### 1. Clone the repository

```bash
git clone https://github.com/seakrebel/macos-animation-fix.git
cd macos-animation-fix
```

### 2. Build and run

The build is a single command — the `build.sh` script compiles `main.swift`,
assembles `CompositorFix.app` and writes its `Info.plist`:

```bash
./build.sh
```

Useful variants:

```bash
./build.sh run       # build and run from the terminal (shows the app's log)
./build.sh install   # build, install to /Applications, and launch it
```

The script is a thin wrapper around `swiftc` (against AppKit,
ScreenCaptureKit and CoreMedia), bundle assembly, and a minimal
`Info.plist` with `LSUIElement` — see `build.sh` for the exact steps.

## Keeping the session alive

`SCStream` sessions are invalidated by the system whenever the display
environment changes:

- the Mac sleeps or wakes (including closing / opening the lid),
- the screen is locked or unlocked,
- displays are connected or disconnected (e.g. a docking station),
- a display wakes from display sleep.

CompositorFix now watches for these events and automatically recreates the
capture session:

- `NSWorkspace.didWakeNotification` / `screensDidWakeNotification` (sleep/wake)
- `NSWorkspace.sessionDidBecomeActiveNotification` (unlock)
- `NSApplication.didChangeScreenParametersNotification` (dock, external displays)

The stream delegate (`SCStreamDelegate.stream(_:didStopWithError:)`) restarts
the session if the system kills it for any other reason.  Restarts are
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

**The app never sees your screen content.**  The `SCStream` is created
without an `SCStreamOutput`, so captured frames are never delivered to the
process — they are not buffered, encoded, logged, or stored anywhere.  The
app's only effect is keeping the capture *session* active.

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

- The whole implementation is the single `main.swift` file in this
  repository.  Build it from source and audit it yourself; do not run
  prebuilt binaries from untrusted sources.
- While the stream is active, macOS shows its own screen-recording
  indicator in the menu bar, independently of this app.

**What you should understand:** the app holds Screen Recording permission,
which is inherent to its purpose — macOS treats starting a `SCStream` as
screen recording.  As with any recording app, a modified build would have
access to the screen, and the binary itself is ad-hoc signed and not
sandboxed.  For the code in this repository that is irrelevant (it does
nothing but start a capture session), but it is why you should always build
and run the app from the published source.

## Important disclaimer

This is an experimental workaround.

It does **not** prove that the underlying macOS bug is specifically a
"Metal compositor" bug or that `WindowServer` is definitely switching to a
particular internal rendering path.

The exact mechanism is currently unknown.

The project is based on observed behavior:

```text
SCStream inactive
    ↓
UI animations stutter

SCStream.startCapture()
    ↓
UI animations become smooth
