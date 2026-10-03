#!/bin/bash
# Hands-off check that a game's own SDL sees a Bluetooth controller through NS2 Bridge's helper
# (see tools/vpadcheck.c). Needs NS2 Bridge running with a Switch 2 controller connected over Bluetooth.
#
#   ./scripts/vpad-check.sh /Applications/BattleShip.app [seconds]
#
# Uses the game's bundled SDL and NS2 Bridge's current helper (from build/). Exit status 0 = PASS.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: vpad-check.sh Game.app [seconds]}"
SECS="${2:-6}"
FW="$APP/Contents/Frameworks"
HELPER="build/NS2 Bridge.app/Contents/Resources/ns2rumble.dylib"
[ -f "$HELPER" ] || { echo "Build NS2 Bridge first: ./scripts/build-app.sh"; exit 2; }

# The SDL the game links (sdl2-compat counts as SDL2: it's what the game calls).
LIB="" MAJOR=""
for cand in "$FW/libSDL2-2.0.0.dylib" "$FW/SDL2.framework/SDL2" "$FW/libSDL3.0.dylib" "$FW/SDL3.framework/SDL3"; do
    if [ -f "$cand" ]; then
        LIB="$cand"
        case "$cand" in *SDL3*) MAJOR=3 ;; *) MAJOR=2 ;; esac
        break
    fi
done
[ -n "$LIB" ] || { echo "No bundled SDL found in $FW."; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Check.app/Contents/MacOS"
ln -s "$FW" "$WORK/Check.app/Contents/Frameworks"
cc -O1 -DSDL_MAJOR="$MAJOR" tools/vpadcheck.c "$LIB" -rpath @executable_path/../Frameworks \
   -o "$WORK/Check.app/Contents/MacOS/vpadcheck"

echo "SDL: $LIB (SDL$MAJOR API) · helper: $(strings -a "$HELPER" | grep -m1 NS2RUMBLE_VERSION)"
NS2_LAUNCHED=1 DYLD_INSERT_LIBRARIES="$PWD/$HELPER" "$WORK/Check.app/Contents/MacOS/vpadcheck" "$SECS"
