#!/bin/zsh
# Builds "AI Usage.app" into ./build and (optionally) launches it.
#   ./build.sh          build only
#   ./build.sh run      build, then (re)launch
#   ./build.sh install  build, copy to /Applications, then (re)launch
set -euo pipefail
cd "$(dirname "$0")"

APP="build/AI Usage.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
  -target "$(uname -m)-apple-macos14.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/AI Usage"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "built: $APP"

case "${1:-}" in
  run)
    pkill -x "AI Usage" 2>/dev/null || true
    open "$APP"
    ;;
  install)
    pkill -x "AI Usage" 2>/dev/null || true
    rm -rf "/Applications/AI Usage.app"
    cp -R "$APP" /Applications/
    open "/Applications/AI Usage.app"
    echo "installed: /Applications/AI Usage.app"
    ;;
esac
