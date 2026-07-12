#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="BarrelMac"
BUNDLE_ID="dev.bruno.BarrelMac"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.icns"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

cd "$ROOT_DIR"
swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Barrel</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Barrel uses Finder Automation only when Quick Send opens to read the files you currently selected.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    [[ -d "$APP_BUNDLE" ]] || { echo "missing app bundle: $APP_BUNDLE" >&2; exit 1; }
    [[ -x "$APP_BINARY" ]] || { echo "missing app executable: $APP_BINARY" >&2; exit 1; }
    [[ -f "$APP_RESOURCES/AppIcon.icns" ]] || { echo "missing app icon" >&2; exit 1; }
    [[ -f "$INFO_PLIST" ]] || { echo "missing Info.plist" >&2; exit 1; }
    /usr/bin/plutil -lint "$INFO_PLIST" >/dev/null

    VERIFY_LOG="$(mktemp -t barrel-verify.XXXXXX)"
    VERIFY_PID=""
    cleanup_verify() {
      if [[ -n "$VERIFY_PID" ]] && kill -0 "$VERIFY_PID" 2>/dev/null; then
        kill -TERM "$VERIFY_PID" 2>/dev/null || true
        wait "$VERIFY_PID" 2>/dev/null || true
      fi
      rm -f "$VERIFY_LOG"
    }
    trap cleanup_verify EXIT

    "$APP_BINARY" >"$VERIFY_LOG" 2>&1 &
    VERIFY_PID=$!
    for _ in {1..20}; do
      if kill -0 "$VERIFY_PID" 2>/dev/null; then
        break
      fi
      sleep 0.25
    done
    if ! kill -0 "$VERIFY_PID" 2>/dev/null; then
      cat "$VERIFY_LOG" >&2
      echo "verification launch exited before its PID became live" >&2
      exit 1
    fi
    sleep 1
    if ! kill -0 "$VERIFY_PID" 2>/dev/null; then
      cat "$VERIFY_LOG" >&2
      echo "verification process exited during the launch check" >&2
      exit 1
    fi
    VERIFY_COMMAND="$(/bin/ps -p "$VERIFY_PID" -o comm= | xargs)"
    [[ "$VERIFY_COMMAND" == "$APP_BINARY" ]] || {
      echo "unexpected process for PID $VERIFY_PID: $VERIFY_COMMAND" >&2
      exit 1
    }
    echo "verified $APP_BUNDLE with PID $VERIFY_PID"
    cleanup_verify
    trap - EXIT
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
