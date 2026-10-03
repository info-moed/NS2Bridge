---
title: Releasing
parent: For developers
nav_order: 2
---

# Releasing

## Versioning

[Semantic versioning](https://semver.org): **patch** (1.0.x) for fixes and documentation, **minor** (1.x.0) for new
features, **major** for changes that break how people use it (none planned). The game helper has its own counter,
`NS2RUMBLE_VERSION` in `Hooks/ns2rumble.c`: bump it whenever the helper changes, so games with an installed copy get
an **Update helper in game** button.

## Checklist

1. All changes merged; `CHANGELOG.md` has a section for the new version (Added / Changed / Fixed).
2. Version bumped in `Resources/Info.plist` (`CFBundleShortVersionString`, and `CFBundleVersion` = digits without
   dots); `NS2RUMBLE_VERSION` bumped if the helper changed.
3. The [hardware QA checklist](testing.md#hardware-qa-checklist-each-release) is done and recorded.
4. Screenshots refreshed if the UI changed: `open -n "build/NS2 Bridge.app" --args --screenshot-tour /tmp/shots`,
   then copy `tab-*.png` into `docs/images/` (resized to 1600 px wide).
5. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`.

## What the release workflow does

Pushing a `v*` tag runs `.github/workflows/release.yml` on a GitHub macOS runner:

1. `scripts/package.sh`: clean build, unit tests, universal app, `NS2Bridge-X.Y.Z-macOS.zip` and its SHA-256.
2. A privacy scan of the zip's contents (no home-folder paths, emails or serial numbers).
3. A GitHub release with the versioned zip, a stable-named copy (`NS2Bridge-macOS.zip`, which the website's Download
   button points at), the checksum, and the CHANGELOG section as notes.
That's all: the app's update check asks GitHub's Releases API directly, and the Homebrew tap
(`info-moed/homebrew-tap`) checks daily for a new release, verifies its SHA-256 and bumps the cask by itself.

Building on the runner also keeps personal paths out of the binaries: Swift embeds source file paths, so a release
built in your home folder would carry `/Users/<you>/…`. If you ever build a release locally, do it from a neutral
path such as `/tmp/NS2Bridge`.
