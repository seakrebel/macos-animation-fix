#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

VARIANT="cg"   # default: CGDisplayStream (no replayd)
ACTION="build"

usage() {
    echo "Usage: $0 [variant] [run|install]"
    echo ""
    echo "  variant  cg (default)  CGDisplayStream — no replayd, lighter"
    echo "           sck           ScreenCaptureKit — officially supported"
    echo ""
    echo "  (no args)    build the app in the current directory"
    echo "  run          build and run from the terminal (shows its log)"
    echo "  install      build, install to /Applications, and launch it"
    echo ""
    echo "Examples:"
    echo "  $0 run        # main.swift → AnimationFix.app (default)"
    echo "  $0 sck run    # main-sck.swift → AnimationFixSck.app"
}

case "${1:-}" in
    cg|sck)
        VARIANT="$1"
        shift || true
        ;;
esac

case "${1:-}" in
    ""|build)
        ACTION="build"
        ;;
    run)
        ACTION="run"
        ;;
    install)
        ACTION="install"
        ;;
    *)
        usage
        exit 1
        ;;
esac

case "$VARIANT" in
    cg)  SRC="main.swift";     APP_NAME="AnimationFix" ;;
    sck) SRC="main-sck.swift"; APP_NAME="AnimationFixSck" ;;
esac

build() {
    echo "==> Compiling $SRC → $APP_NAME..."
    if [ "$VARIANT" = "cg" ]; then
        # CGDisplayStream is marked obsolete in the macOS 15+ SDK, so target
        # an older deployment version to keep it callable (the symbols still
        # exist at runtime on macOS 26/27 — verified).  If a future macOS
        # removes them, switch to the supported SCK variant: ./build.sh sck.
        swiftc "$SRC" \
            -target "$(uname -m)-apple-macos14.0" \
            -o "$APP_NAME" \
            -framework AppKit \
            -framework CoreGraphics \
            -framework CoreVideo \
            -framework IOSurface
    else
        swiftc "$SRC" \
            -o "$APP_NAME" \
            -framework AppKit \
            -framework ScreenCaptureKit \
            -framework CoreMedia
    fi

    echo "==> Assembling $APP_NAME.app..."
    rm -rf "$APP_NAME.app"
    mkdir -p "$APP_NAME.app/Contents/MacOS"
    mv "$APP_NAME" "$APP_NAME.app/Contents/MacOS/$APP_NAME"

    cat > "$APP_NAME.app/Contents/Info.plist" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">

<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>__APP_NAME__</string>

    <key>CFBundleIdentifier</key>
    <string>local.__APP_NAME__</string>

    <key>CFBundleName</key>
    <string>__APP_NAME__</string>

    <key>CFBundleDisplayName</key>
    <string>__APP_NAME__</string>

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
PLIST_EOF

    sed -i '' "s/__APP_NAME__/$APP_NAME/g" "$APP_NAME.app/Contents/Info.plist"

    echo "==> Built $APP_NAME.app"
}

case "$ACTION" in
    build)
        build
        ;;
    run)
        build
        echo "==> Running (Ctrl+C to quit)..."
        exec "$APP_NAME.app/Contents/MacOS/$APP_NAME"
        ;;
    install)
        build
        echo "==> Installing to /Applications..."
        pkill -x "$APP_NAME" 2>/dev/null || true
        rm -rf "/Applications/$APP_NAME.app"
        cp -R "$APP_NAME.app" "/Applications/$APP_NAME.app"
        echo "==> Launching..."
        open "/Applications/$APP_NAME.app"
        ;;
esac
