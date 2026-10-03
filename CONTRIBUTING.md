# Contributing to NS2 Bridge

Thanks for helping! NS2 Bridge is a small project, and the most useful contributions are often not code:

- **Compatibility reports.** Tried a game or emulator? Open a *Compatibility report* issue, whether it worked
  or not. These feed the [compatibility list](docs/reference/compatibility.md).
- **Bug reports with a diagnostics report attached** (Diagnostics tab → *Export Diagnostics Report…*).
- **Protocol findings** backed by evidence (see "Protocol facts" below).
- **Documentation fixes**: anything that confused you is worth fixing.
- **Code.**

Questions go to [Discussions](https://github.com/info-moed/NS2Bridge/discussions), not Issues. Be kind: see the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Building and testing

You need macOS 15 or later and Xcode 16 or later (or its command-line tools). No Apple Developer account.

```bash
swift test                    # unit tests (no controller needed)
./scripts/build-app.sh        # builds "build/NS2 Bridge.app" (app, game helper, force-feedback plug-in)
open "build/NS2 Bridge.app"
```

More in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): the test tools (`scripts/sdl-check.sh`, `scripts/vpad-check.sh`),
the research channel for live Bluetooth work, and hard-won facts about macOS, SDL and the controllers.

### Before you open a pull request

- `swift test` passes, and the helper and plug-in build without warnings (`./scripts/build-app.sh`).
- New logic has a unit test where it can (parsing, encoding, routing, calibration). Hardware behavior that can't
  be unit-tested is described in the pull request with what you measured.
- Docs are updated: user-visible changes in the README or the guide; protocol changes in `docs/PROTOCOL.md`;
  an entry under the next version in `CHANGELOG.md`.
- Mark hardware status honestly: ✅ only for what you tested on a real controller, 🧪 for built and unit-tested.

## Protocol facts

Every fact in [docs/PROTOCOL.md](docs/PROTOCOL.md) carries a marker:

- **✅ Verified**: measured on real hardware. Include the evidence: a capture in `research/captures/`, a log in
  `research/data/`, or a script in `research/scripts/` that reproduces the finding, plus a note in
  `research/FINDINGS.md`.
- **📚 Documented**: from a public source, linked.
- **❓ Unknown**: say so rather than guess.

Controller captures (`.ns2cap`) can contain the controller's **serial number** in some reports. Only commit
captures of input reports, check them first, and never commit flash-read replies. The `.gitignore` keeps
captures out of the repository except the reviewed ones in `research/captures/`.

## Code

- Match the surrounding code: naming, comment density, idioms, and its hand-aligned comments and tables
  (`.editorconfig` covers whitespace). C (the game helper and plug-in) builds with `-Wall -Werror` in CI.
- **No third-party code.** NS2 Bridge contains only original code (see [LEGAL.md](LEGAL.md) and
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)). Reading other projects to learn how a device behaves is fine;
  copying their code or text is not. Credit every project you consulted in THIRD_PARTY_NOTICES.md.
- **Safety:** never send firmware-update (`0x0D`), pairing (`0x15`) or flash write/erase commands to a controller,
  and keep the HD Rumble amplitude cap (450).
- **Privacy:** nothing about the user leaves the Mac. No telemetry or analytics; the only network access is the
  opt-in update check that LEGAL.md describes.
- Using an AI assistant is fine; you are responsible for the result, as with any code (LEGAL.md §6a).

## Licensing of contributions

NS2 Bridge is MIT-licensed. By contributing, you agree that your contribution is licensed under the same
[MIT License](LICENSE) (inbound = outbound), and that you have the right to contribute it.
