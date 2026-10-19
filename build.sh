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

# Wait for the previous process to exit before replacing/reopening its app bundle.
# LaunchServices can return -600 if the old instance is still terminating.
stop_app() {
  pkill -x "AI Usage" 2>/dev/null || true
  for attempt in {1..50}; do
    if ! pgrep -x "AI Usage" >/dev/null; then return 0; fi
    sleep 0.1
  done
  echo "AI Usage is still quitting; installation stopped. Try again shortly." >&2
  return 1
}

# LaunchServices may retain an exiting instance briefly after its PID disappears.
launch_app() {
  local launch_error
  for attempt in {1..3}; do
    if launch_error=$(open "$1" 2>&1); then return 0; fi
    if [[ "$launch_error" != *"error -600"* ]]; then
      echo "$launch_error" >&2
      return 1
    fi
    sleep 0.5
  done
  echo "$launch_error" >&2
  return 1
}

case "${1:-}" in
  run)
    stop_app
    launch_app "$APP"
    ;;
  install)
    stop_app
    rm -rf "/Applications/AI Usage.app"
    cp -R "$APP" /Applications/
    launch_app "/Applications/AI Usage.app"
    echo "installed: /Applications/AI Usage.app"
    ;;
esac
