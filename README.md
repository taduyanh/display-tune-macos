# DisplayTune

Menu-bar app for macOS that gives external monitors what macOS does not: **real brightness control** and **sharp HiDPI**.

- **Hardware brightness** over DDC/CI (works when macOS has no brightness slider for the monitor), plus **software dimming** (gamma) as an extra / fallback
- **Brightness keys (F1/F2)** drive the external display under the mouse pointer (1/16 steps, ⇧⌥ = fine steps) with an on-screen indicator; keys on the built-in display are untouched
- **Resolution, refresh rate and HiDPI** switching, including a "High Resolution (HiDPI)" toggle (same size, 2x ⇄ 1:1) that fixes blurry text on 4K monitors running a 1080p-sized desktop
- **Extra HiDPI sizes** for panels macOS offers no HiDPI for (e.g. a QHD monitor at "looks like 1920×1080") — experimental
- A small **CLI** (same binary) for scripting

## Requirements
- macOS 14+ (built with `-target …-macos14.0`; **developed and tested only on macOS 27 / Apple M2** — other versions are untested)
- Apple Silicon for DDC brightness. On an Intel Mac the brightness slider shows "DDC not available" and the keys fall back to software dimming (resolution / HiDPI still work; untested)
- Xcode Command Line Tools: `xcode-select --install` (provides `swiftc` and the macOS SDK). No Xcode project, no Apple Developer account

## Quick start
```
git clone https://github.com/taduyanh/display-tune-macos.git
cd display-tune-macos
./tools/make_signing_cert.sh   # once, recommended: stable signing identity (see "Permissions & signing")
./build.sh install             # builds, signs, copies to ~/Applications
open ~/Applications/DisplayTune.app
```
A display icon appears in the menu bar. For the brightness keys, open its menu → **Brightness keys: allow Accessibility access…** and switch DisplayTune on in *System Settings → Privacy & Security → Accessibility* (macOS 27 labels the page "Device Control and Data Access"). No restart needed; the app notices within ~2 s and the menu then shows a ✓.

Check that it works:
```
~/Applications/DisplayTune.app/Contents/MacOS/DisplayTune --cli list
```
Each external display should be listed with `brightness (DDC): N / 100`. `./build.sh` alone builds into `build/` without installing.

## Permissions & signing
macOS ties the Accessibility permission to the app's **code requirement**. An ad-hoc signature (`codesign -s -`) is just a hash of the build, so it changes on *every* rebuild and silently invalidates the permission — the switch in Settings still looks on, but the brightness keys stop working.

`tools/make_signing_cert.sh` creates a self-signed identity ("DisplayTune Local Signing") in its **own keychain** (`~/Library/Keychains/displaytune-signing.keychain-db`; nothing is added to your login keychain, no trust settings change, no password prompts). `build.sh` signs with it automatically, so the requirement (`identifier … and certificate leaf = H"…"`) stays the same across rebuilds and the permission survives. Without the identity `build.sh` falls back to ad-hoc signing and prints a note.

- Switching identity (ad-hoc ⇄ local identity, or `make_signing_cert.sh --reset`) changes the requirement: reset once and grant again: `tccutil reset Accessibility dev.taduyanh.DisplayTune`
- Builds use the **hardened runtime** (`--options runtime`), which blocks `DYLD_INSERT_LIBRARIES`-style code injection into the app (it holds the Accessibility permission)
- The identity is local to each Mac and is only needed to *sign* builds, not to run the app
- To publish your own fork, change `CFBundleIdentifier` in `Info.plist` (and the `dev.taduyanh` prefix in this README)

## CLI
```
DisplayTune --cli list
DisplayTune --cli brightness 0 70            # get / set DDC brightness of display 0
DisplayTune --cli mode 0 1920x1080 hidpi 120 # [hidpi|lodpi] [hz]
DisplayTune --cli keystep 0 up               # simulate one brightness-key press
DisplayTune --cli menu                       # print the menu structure
DisplayTune --cli bench 1000                 # rebuild the menu 1000x, report time + memory (leak check)
```
(`DisplayTune` = `DisplayTune.app/Contents/MacOS/DisplayTune`.) Exit status: 0 ok, 1 operation failed, 2 bad usage.

## Repository layout
| Path | Purpose |
|---|---|
| `Sources/main.swift` | entry point: CLI or menu-bar app |
| `Sources/UI.swift` | status item, menu, sliders, Keep/Revert prompt |
| `Sources/Displays.swift` | display model, mode catalog, DDC state, `DisplayManager` |
| `Sources/DDC.swift` | DDC/CI over `IOAVService` (private API via `dlsym`) |
| `Sources/BrightnessKeys.swift` | event tap for F1/F2 + on-screen indicator |
| `Sources/FlexibleHiDPI.swift` | virtual-display based HiDPI for non-Retina panels |
| `Sources/CLI.swift` | `--cli` commands |
| `Bridge.h` | declarations of the private `CGVirtualDisplay*` classes |
| `build.sh` | build + sign (+ `install`) |
| `tools/make_signing_cert.sh` | one-time local signing identity |
| `tools/make_icon.swift` | generates `Resources/AppIcon.icns` (flat "Metro" tile) |

## How it works (same building blocks BetterDisplay links against)
| Feature | API |
|---|---|
| Hardware brightness | `IOAVServiceCreateWithService` / `IOAVServiceWriteI2C` / `ReadI2C` (private). DDC/CI VCP `0x10`, I2C address `0x37`. The external `DCPAVServiceProxy` that follows each `AppleCLCD2` node in the IORegistry is that display's channel |
| Software dim | `CGSetDisplayTransferByFormula` (lasts only while the app runs) |
| Resolution / HiDPI / Hz | public `CGDisplayCopyAllDisplayModes` + `CGConfigureDisplayWithDisplayMode` |
| Extra HiDPI | private `CGVirtualDisplay` (hiDPI=1, e.g. 1920×1080 → 3840×2160 backing store) + `CGConfigureDisplayMirrorOfDisplay`, so the physical panel mirrors it and the GPU downsamples. Asks Keep / Revert and auto-reverts after 15 s |
| Brightness keys | `CGEventTap` on `NX_SYSDEFINED` events (keys 2/3), active only when the pointer is on an external display |

## Troubleshooting
| Symptom | Cause / fix |
|---|---|
| Menu says "Brightness keys: allow Accessibility access…" although the switch in Settings is on | The switch belongs to an older signature. `tccutil reset Accessibility dev.taduyanh.DisplayTune`, reopen the app, enable it again |
| Brightness slider says "DDC not available" | The monitor does not answer DDC/CI: enable "DDC/CI" in its on-screen menu; some docks/HDMI adapters do not pass DDC. Software dimming still works |
| `build.sh` says no signing identity | Run `tools/make_signing_cert.sh` (or accept ad-hoc signing and re-grant after each rebuild) |
| `make_signing_cert.sh` reports an unusable identity | `tools/make_signing_cert.sh --reset`, then reset + re-grant Accessibility |
| Text is blurry on a 4K monitor | Menu → **High Resolution (HiDPI)** (or pick a "HiDPI" resolution) |
| Screen goes black after "Extra HiDPI" | Do nothing: it reverts by itself after 15 s |

## Uninstall
Quit the app, then:
```
rm -rf ~/Applications/DisplayTune.app
tccutil reset Accessibility dev.taduyanh.DisplayTune
defaults delete dev.taduyanh.DisplayTune
security delete-keychain ~/Library/Keychains/displaytune-signing.keychain-db; rm -f ~/Library/Keychains/displaytune-signing.pass
```
(Also remove it from *System Settings → General → Login Items* if you enabled "Launch at Login".)

## Security notes
- No network access, no subprocesses, no file writes except the user-requested `--cli osd-preview <file>`; preferences (dim levels, toggles) live in `UserDefaults`
- Needs the **Accessibility** permission for the F1/F2 event tap. The tap only receives system-defined (media/brightness) events — not typed keys — and only reacts to brightness keys. The app is **not sandboxed** (IOKit / private display APIs require it) and uses **private APIs** resolved with `dlsym`; a macOS update may change them
- The local signing identity is a *developer convenience*: its key sits in a keychain whose random password is stored in a 0600 file, and `codesign` may use it without a prompt. **Any process running as your user can therefore sign code as "DisplayTune Local Signing" and inherit DisplayTune's Accessibility permission.** If that is not acceptable, don't create the identity (ad-hoc signing needs a manual re-grant after each rebuild) or delete it after building (see Uninstall)
- Builds are not notarized. A copy you *download* would be quarantined by Gatekeeper; build from source instead (a locally built app is not quarantined)
- `build.sh` and `tools/make_signing_cert.sh` run local commands only (`swiftc`, `codesign`, `security`, `openssl`); read them before running

## Limits / not verified
- "Extra HiDPI sizes" has not been tried on a QHD panel yet; session-only (not restored at login)
- Two identical monitors: they get separate entries, but pairing with their DDC channel follows IORegistry order (unverified)
- Software dim resets when the app quits
- Intel Macs and macOS versions other than 27 are untested
