#!/bin/zsh
# Captures the README screenshots (light and dark) and the banner from DriveDock's demo mode:
# made-up servers, nothing is mounted, the keychain and Finder stay untouched.
#
# macOS only lets an app capture windows – even its own – with the screen recording permission.
# The first run asks for it (System Settings → Privacy & Security → Screen & System Audio
# Recording → DriveDock). Switch it on, run again, and switch it off afterwards if you like.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/build/DriveDock.app"
OUT="$PWD/docs/images"
LOG="$(mktemp -t drivedock-screenshots)"
trap 'rm -f "$LOG"' EXIT

[[ -d "$APP" ]] || scripts/build-app.sh
mkdir -p "$OUT"

# Always English, whatever the system language; the folder name as on an English system.
# Don't click around while it runs: the demo window has to stay in front.
demo() {
  for attempt in 1 2 3; do
    : > "$LOG"
    open -n -W "$APP" --stdout "$LOG" --stderr /dev/null --args --demo "$@" \
      -AppleLanguages '(en)' -AppleLocale en_US -mountRootName "Network Drives" &
    # An app started in the background may not take the focus by itself (its windows would
    # look inactive); opening it again from here brings it to the front.
    sleep 1.5; open -a "$APP"
    sleep 1; open -a "$APP"
    wait
    if grep -q "failed" "$LOG"; then cat "$LOG"; exit 1; fi
    grep -q "wasn't active" "$LOG" || break
  done
  cat "$LOG"
}

for appearance in light dark; do
  demo --show menu --appearance "$appearance" --capture "$OUT/menu-$appearance.png"
  demo --show servers --scroll 560 --appearance "$appearance" --capture "$OUT/servers-$appearance.png"
  demo --show general --appearance "$appearance" --capture "$OUT/general-$appearance.png"
done

: > "$LOG"
open -n -W "$APP" --stdout "$LOG" --args --render-banner "$OUT"
cat "$LOG"
