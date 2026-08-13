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

### 2. Compile and run

```bash
swiftc main.swift \
    -o CompositorFix \
    -framework AppKit \
    -framework ScreenCaptureKit \
    -framework CoreMedia

mkdir -p CompositorFix.app/Contents/MacOS

mv CompositorFix \
    CompositorFix.app/Contents/MacOS/CompositorFix

cat > CompositorFix.app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC
 "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">

<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CompositorFix</string>

    <key>CFBundleIdentifier</key>
    <string>local.CompositorFix</string>

    <key>CFBundleName</key>
    <string>CompositorFix</string>

    <key>CFBundleDisplayName</key>
    <string>CompositorFix</string>

    <key>CFBundlePackageType</key>
    <string>APPL</string>

    <key>CFBundleVersion</key>
    <string>1</string>

    <key>CFBundleShortVersionString</key>
    <string>1.0</string>

    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

open CompositorFix.app
```

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
