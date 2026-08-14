#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="AnimationFix"

usage() {
    echo "Usage: $0 [run|install]"
    echo "  (no args)  build $APP_NAME.app in the current directory"
    echo "  run        build and run the binary from the terminal (shows its log)"
    echo "  install    build, install to /Applications, and launch it"
}

build() {
    echo "==> Compiling..."
    swiftc main.swift \
        -o "$APP_NAME" \
        -framework AppKit \
        -framework ScreenCaptureKit \
        -framework CoreMedia

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
    <string>AnimationFix</string>

    <key>CFBundleIdentifier</key>
    <string>local.AnimationFix</string>

    <key>CFBundleName</key>
    <string>AnimationFix</string>

    <key>CFBundleDisplayName</key>
    <string>AnimationFix</string>

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

    echo "==> Built $APP_NAME.app"
}

case "${1:-}" in
    "")
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
    *)
        usage
        exit 1
        ;;
esac
