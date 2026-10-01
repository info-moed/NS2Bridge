#!/bin/zsh
# Clean, from-scratch release: wipes build outputs, runs the tests, builds the app,
# and produces dist/NS2Bridge-<version>-macOS.zip plus a SHA-256 checksum.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
NAME="NS2Bridge-$VERSION-macOS"

echo "==> Cleaning"
rm -rf .build build dist

echo "==> Running tests"
swift test

echo "==> Rendering icon"
swift scripts/make-icon.swift "$PWD"

echo "==> Building app"
./scripts/build-app.sh

echo "==> Assembling $NAME"
STAGE="dist/$NAME"
mkdir -p "$STAGE"
ditto "build/NS2 Bridge.app" "$STAGE/NS2 Bridge.app"
cp README.md LICENSE LEGAL.md THIRD_PARTY_NOTICES.md CHANGELOG.md "$STAGE/"
cp docs/INSTALL.md "$STAGE/INSTALL.md"

echo "==> Zipping"
( cd dist && ditto -c -k --norsrc --noextattr --noqtn --keepParent "$NAME" "$NAME.zip" )   # no extended attributes (quarantine, provenance)
( cd dist && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256" )
rm -rf "$STAGE"

echo
echo "Release ready:"
ls -lh dist
cat "dist/$NAME.zip.sha256"
