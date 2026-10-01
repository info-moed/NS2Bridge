# Installing NS2 Bridge

## Requirements

- macOS 15 (Sequoia) or newer. Developed and tested on macOS 27 with Apple Silicon; the build is universal,
  but it has not been tried on an Intel Mac.
- One or more of: **Nintendo Switch 2 Pro Controller**, **Nintendo Switch 2 NSO GameCube Controller**,
  **Nintendo Switch Online N64 Controller**.
- A **USB-C data cable**. Charge-only cables don't work: the controller charges but never appears.

## Option A: install the release zip

1. Download `NS2Bridge-1.0.0-macOS.zip` from the [GitHub Releases page](https://github.com/info-moed/NS2Bridge/releases). Optionally, check it against the
   published SHA-256:
   ```bash
   shasum -a 256 NS2Bridge-1.0.0-macOS.zip
   ```
2. Double-click the zip, then drag **NS2 Bridge.app** into **Applications**.
3. **First launch (one time only).** NS2 Bridge isn't signed with a paid Apple Developer ID, so macOS
   blocks the first launch:
   1. Open NS2 Bridge. macOS says it "could not verify" the app. Click **Done**.
   2. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to
      "NS2 Bridge was blocked".
   3. Confirm with your password or Touch ID, then click **Open**.

   Or, in Terminal:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/NS2 Bridge.app"
   ```
4. Plug in a controller. A colored pill appears in the menu bar (e.g. **GC** in blue for player 1) and
   the window shows the controller with a green dot.
5. Recommended: **Setup → Let SDL games and emulators use this controller**, and **Setup → Open NS2
   Bridge at login** (its settings for Finder-launched games only last until you log out otherwise).

### Permissions macOS may ask for

| Prompt | Why | Where to change it later |
|---|---|---|
| Bluetooth | Wireless Switch 2 Pro / GameCube | System Settings → Privacy & Security → Bluetooth |
| Notifications | Optional battery charge alert | System Settings → Notifications |
| App Management | Only when you install the helper into a game | System Settings → Privacy & Security → App Management |

Because the app is ad-hoc signed, macOS may ask again after you install a newer build.

## Option B: build from source

You need Xcode 16 or newer (the command-line tools are enough), with Swift 6.

```bash
git clone https://github.com/info-moed/NS2Bridge.git
cd NS2Bridge
./scripts/build-app.sh            # → build/NS2 Bridge.app
open "build/NS2 Bridge.app"
```

Full release build from scratch (clean → tests → icon → app → zip + checksum):

```bash
./scripts/package.sh              # → dist/NS2Bridge-<version>-macOS.zip + .sha256
```

No Apple Developer account is needed at any step.

## Uninstalling

1. In NS2 Bridge, **Games**: for every game with the helper installed, click **Remove helper from game**.
   This restores the game's original files from the backup.
2. Quit NS2 Bridge (menu bar → Quit). Its force-feedback plug-in is detached from the controllers.
3. Delete **NS2 Bridge.app** from Applications.
4. Optional clean-up:
   ```bash
   defaults delete local.ns2bridge                                  # settings, profiles, calibration
   rm -rf ~/Library/Application\ Support/NS2Bridge                   # battery history, game settings, backups
   launchctl unsetenv SDL_JOYSTICK_MFI; launchctl unsetenv SDL_GAMECONTROLLERCONFIG
   launchctl unsetenv SDL_JOYSTICK_HIDAPI; launchctl unsetenv SDL_JOYSTICK_HIDAPI_NINTENDO_CLASSIC
   rm -f ~/Library/LaunchAgents/local.ns2bridge.sdl-env.plist       # login item that restores those settings
   ```
   (Turning **Setup → Let SDL games…** off before quitting removes the login item for you.)
   The `launchctl` lines are only needed if the Setup switch was on and you haven't logged out since.
   Remove the backups folder **after** step 1, not before.
