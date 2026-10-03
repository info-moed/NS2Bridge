#!/bin/bash
# End-to-end test of the game helper's virtual gamepads against a fake SDL3 and SDL2 (Tests/HelperTests/).
# No game, controller or running NS2 Bridge needed. Exit status 0 = both pass.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
clang -dynamiclib -O1 -Wall -Werror -framework CoreFoundation -install_name @loader_path/ns2rumble.dylib \
    -o "$WORK/ns2rumble.dylib" Hooks/ns2rumble.c

status=0
for flavor in 3 2; do
    if [ "$flavor" = 3 ]; then lib=libSDL3.0.dylib; else lib=libSDL2-2.0.0.dylib; fi
    mkdir -p "$WORK/sdl$flavor"
    clang -dynamiclib -Wall -Werror -DFAKE_SDL$flavor -install_name "@rpath/$lib" \
        -o "$WORK/sdl$flavor/$lib" Tests/HelperTests/fake_sdl.c
    clang -Wall -Werror -DFAKE_SDL$flavor Tests/HelperTests/helper_test.c "$WORK/sdl$flavor/$lib" \
        -rpath "$WORK/sdl$flavor" -o "$WORK/helper_test$flavor"
    "$WORK/helper_test$flavor" "$WORK/ns2rumble.dylib" || status=1
done
exit $status
