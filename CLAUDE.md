# DisplayTune — notes for Claude Code

macOS menu-bar app (Swift/AppKit, `swiftc` only — no Xcode project, no package manager). See README.md for the full picture.

## Build & verify
- `./tools/make_signing_cert.sh` once, then `./build.sh` (builds into `build/`) or `./build.sh install` (also copies to `~/Applications`). Always build through `build.sh`: it signs with the stable local identity + hardened runtime. **Never ad-hoc sign by hand** (`codesign -s -`): the Accessibility permission is tied to the code requirement and an ad-hoc signature changes every build, which silently breaks the brightness keys.
- There are no unit tests. Verify with the CLI of the built binary: `--cli list`, `--cli menu`, `--cli bench 300` (leak/time check — it pumps the run loop between iterations on purpose), `--cli keystep 0 up|down`, `--cli osd-preview <file.png>`.
- The CLI runs in a *separate process*: its menu output and Accessibility state do **not** reflect the running GUI app. To check the F1/F2 tap of the installed app list event taps (`CGGetEventTapList`) and look for the app's pid.
- If the keys stop working after an install: `tccutil reset Accessibility dev.taduyanh.DisplayTune`, relaunch, ask the user to enable it again.

## Gotchas
- This changes the user's live display. Test with no-op or tiny changes (apply the current mode, brightness ±1 then restore); never flip HiDPI/resolution or start "Extra HiDPI" on the screen in use without asking.
- Don't run commands that can pop a GUI password dialog on the user's screen (e.g. `security show-keychain-info` on the locked signing keychain) — they block and the user cannot answer. Use `tools/make_signing_cert.sh` (it self-tests) instead.
- Screenshots usually fail (no Screen Recording permission); render the OSD offscreen with `--cli osd-preview`.
- `DisplayManager.refresh()` walks the IORegistry — call it on display changes only, not per menu open. Build the menu from `ModeCatalog` snapshots (one CoreGraphics query per display).
- Private APIs: `IOAVService*` (DDC) via `dlsym` in `DDC.swift`; `CGVirtualDisplay*` declared in `Bridge.h`.
- Bundle id `dev.taduyanh.DisplayTune`; changing it changes the code requirement (re-grant needed).
