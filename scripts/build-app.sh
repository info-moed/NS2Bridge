#!/bin/zsh
# Builds "build/NS2 Bridge.app" — universal (Apple Silicon + Intel), ad-hoc signed.
# No Apple Developer account needed.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --product NS2Bridge "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

APP="build/NS2 Bridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/NS2Bridge" "$APP/Contents/MacOS/NS2Bridge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift "$PWD"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Game helper (SDL2 + SDL3): injected at launch or installed into a game.
# Universal so it also loads into Intel games running under Rosetta. No SDL link dependency.
clang -dynamiclib -arch arm64 -arch x86_64 -O2 -Wall -framework CoreFoundation \
    -install_name @loader_path/ns2rumble.dylib -o "$APP/Contents/Resources/ns2rumble.dylib" Hooks/ns2rumble.c
codesign --force --sign - "$APP/Contents/Resources/ns2rumble.dylib"

# ForceFeedback plug-in: lets SDL games rumble through macOS force feedback, no game changes.
FF="$APP/Contents/PlugIns/NS2FF.plugin"
mkdir -p "$FF/Contents/MacOS"
cp Hooks/NS2FF/Info.plist "$FF/Contents/Info.plist"
clang -bundle -arch arm64 -arch x86_64 -O2 -Wall -framework CoreFoundation -framework IOKit -framework ForceFeedback \
    -o "$FF/Contents/MacOS/NS2FF" Hooks/NS2FF/NS2FF.c
codesign --force --sign - "$FF"

codesign --force --sign - "$APP"
echo "Built: $PWD/$APP"
