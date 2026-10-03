#!/bin/bash
# Hands-off check of a game's own SDL with a Nintendo controller plugged in (see tools/sdlcheck.c).
#
#   ./scripts/sdl-check.sh /Applications/BattleShip.app [seconds]
#
# Uses the game's bundled SDL, the settings NS2 Bridge wrote for the game, and NS2 Bridge's current
# helper (from build/, so run ./scripts/build-app.sh first). Exit status 0 = PASS.
# NO_SETTINGS=1 / NO_HELPER=1 leave out one protection, to see what the other catches on its own.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: sdl-check.sh Game.app [seconds]}"
SECS="${2:-3}"
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
[ -n "$LIB" ] || { echo "No bundled SDL found in $FW (static or system SDL: this check can't load it)."; exit 2; }

# A throwaway bundle whose Frameworks folder is the game's, so the SDL's @executable_path/@rpath resolve.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Check.app/Contents/MacOS"
ln -s "$FW" "$WORK/Check.app/Contents/Frameworks"
cc -O1 -DSDL_MAJOR="$MAJOR" tools/sdlcheck.c "$LIB" -rpath @executable_path/../Frameworks \
   -o "$WORK/Check.app/Contents/MacOS/sdlcheck" 2>/dev/null

# The game's settings, as the helper would apply them.
BID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
ENVFILE="$HOME/Library/Application Support/NS2Bridge/games/$BID.env"
ENVARGS=()
if [ -n "${NO_SETTINGS:-}" ]; then
    echo "Without NS2 Bridge's settings (NO_SETTINGS)."
elif [ -f "$ENVFILE" ]; then
    while IFS= read -r line; do
        [[ "$line" == \#* || "$line" != *=* ]] && continue
        ENVARGS+=("${line%%=*}=$(printf '%b' "${line#*=}")")
    done < "$ENVFILE"
    echo "Game settings: $ENVFILE"
else
    echo "No NS2 Bridge settings for this game yet (add it in Games): using the Finder-wide ones."
    for k in SDL_JOYSTICK_MFI SDL_JOYSTICK_HIDAPI SDL_JOYSTICK_HIDAPI_NINTENDO_CLASSIC SDL_GAMECONTROLLERCONFIG; do
        v="$(launchctl getenv "$k" || true)"
        [ -n "$v" ] && ENVARGS+=("$k=$v")
    done
fi

echo "SDL: $LIB (SDL$MAJOR API) · helper: $(strings -a "$HELPER" | grep -m1 NS2RUMBLE_VERSION)"
INSERT=("DYLD_INSERT_LIBRARIES=$PWD/$HELPER")
[ -n "${NO_HELPER:-}" ] && { INSERT=(); echo "Without the helper (NO_HELPER)."; }
env -u SDL_JOYSTICK_HIDAPI -u SDL_JOYSTICK_HIDAPI_NINTENDO_CLASSIC \
    ${ENVARGS[@]+"${ENVARGS[@]}"} ${INSERT[@]+"${INSERT[@]}"} "$WORK/Check.app/Contents/MacOS/sdlcheck" "$SECS"
