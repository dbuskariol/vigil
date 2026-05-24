# Vigil

> A macOS menu-bar app and CLI that keeps a Mac fully awake while the lid is closed. Designed for running long jobs (AI agents, builds, syncs) without leaving the laptop propped open.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![License: MIT](https://img.shields.io/badge/License-MIT-green) ![Sparkle 2](https://img.shields.io/badge/Sparkle-2.9%2B-orange)

<img width="421" height="461" alt="image" src="https://github.com/user-attachments/assets/25a32db3-f025-42d1-9dc2-1c33a54e53d6" />


## Install

1. Download `Vigil-X.Y.Z.zip` from [the latest release](https://github.com/dbuskariol/vigil/releases/latest).
2. Unzip it.
3. **Drag `Vigil.app` to `/Applications` before opening it.** macOS Gatekeeper translocates apps launched from `~/Downloads` into a randomised quarantine path; Vigil refuses to enable while translocated and shows a banner asking you to move it.
4. Open `Vigil.app`. The menu-bar icon appears at the right of the status bar.

Auto-updates check daily via Sparkle 2 with EdDSA signature verification. You can disable them in the Sparkle preferences dialog.

## Use

From the menu bar:

- Click the icon, then **Enable** to apply the closed-lid awake profile.
- Click **Disable** to stop and restore the saved settings.
- **Approve All** installs a scoped privileged helper so Enable / Disable run without repeated password prompts.
- **Copy Doctor** copies detailed diagnostics to the clipboard.

From the CLI (after `make install`):

```sh
vigil status
vigil on
vigil off
vigil toggle
vigil doctor
```

`vigil on` runs:

```sh
sudo pmset -a disablesleep 1 sleep 0 disksleep 0 ttyskeepawake 1 tcpkeepalive 1
```

It also installs and starts:

```
~/Library/LaunchAgents/com.vigil.app.assertions.plist
```

`vigil off` stops that LaunchAgent without deleting the background-item registration, and restores the saved `pmset` values from `~/Library/Application Support/Vigil/state.json`.

Display brightness snapshot lives at `~/Library/Application Support/Vigil/visual-state.json`. Keyboard backlight uses Apple's private `CoreBrightness.framework` `KeyboardBrightnessClient`. Display brightness first tries private CoreDisplay / DisplayServices user-brightness APIs and falls back to the older IOKit display-parameter path.

## How it works

Two layers, both reversible:

- A `pmset` profile: `disablesleep 1`, `sleep 0`, `disksleep 0`, `ttyskeepawake 1`, `tcpkeepalive 1`.
- A persistent user LaunchAgent (`com.vigil.app.assertions`) that runs the bundled `vigil` CLI in `hold` mode, taking IOKit power assertions (`IOPMAssertionCreateWithName`) for system sleep, idle system sleep, and idle display sleep.

The LaunchAgent stays registered across enable / disable cycles so macOS doesn't show the "Background Items Added" prompt every time. The agent only runs while a runtime-state JSON file exists (`KeepAlive` `PathState`), so disable is genuinely the off state without unregistering the background item.

Vigil also reads private IOKit power-domain state for diagnostics: `SleepDisabled`, `AppleClamshellState`, `AppleClamshellCausesSleep`.

This design intentionally uses private Apple APIs and `pmset`'s hidden `disablesleep` option. It is **not App Store-safe**. The goal is reliable closed-lid operation, not Apple review.

## Trust model

Vigil takes administrator privileges in two ways:

1. **One-time `Approve All` flow.** The menu app runs `do shell script with administrator privileges` (`NSAppleScript` + macOS SecurityAgent). The privileged shell installs the `vigil` CLI to `/Library/PrivilegedHelperTools/com.vigil.app.helper` (root-owned, `0755`) and writes a sudoers drop-in at `/etc/sudoers.d/vigil-<uid>` (root-owned, `0440`, validated with `visudo -cf`). The sudoers rule is intentionally narrow:

   ```
   <user> ALL=(root) NOPASSWD: /Library/PrivilegedHelperTools/com.vigil.app.helper privileged-pmset-batch *, /Library/PrivilegedHelperTools/com.vigil.app.helper approval-status, /Library/PrivilegedHelperTools/com.vigil.app.helper privileged-version
   ```

   Three verbs only: a `pmset` batch (with an in-binary allowlist of `disablesleep`, `sleep`, `disksleep`, `ttyskeepawake`, `tcpkeepalive`), an `approval-status` probe, and a `privileged-version` probe used for upgrade-mismatch detection. The allowlist is enforced inside the helper (see `Sources/vigil/main.swift`'s `argumentsAreAllowedPMSetBatch`), so a sudoers rule of `privileged-pmset-batch *` is still bounded.

2. **Ad-hoc `do shell script` prompt** when `Approve All` has not been run yet. Each Enable / Disable shows the standard macOS administrator-password sheet.

Auto-updates land via Sparkle 2 from a stable URL: `https://github.com/dbuskariol/vigil/releases/latest/download/appcast.xml`. The appcast is EdDSA-signed; the public key is baked into `Info.plist` (`SUPublicEDKey`). Sparkle refuses to install any update whose signature doesn't verify. After an update, Vigil's menu app probes the on-disk helper's `privileged-version` against its own bundled version and prompts you to re-approve if they disagree (the privileged helper at `/Library/PrivilegedHelperTools/…` is NOT replaced by Sparkle; only the bundled CLI inside the new `.app` is).

Update checks send a `User-Agent: Sparkle/… Vigil/X.Y.Z` header plus your IP to GitHub on a daily schedule. No other system information is collected (`SUEnableSystemProfiling` is off).

## Build from source

Local ad-hoc dev build:

```sh
make app
open dist/Vigil.app
```

CLI only:

```sh
swift build -c release
.build/release/vigil status
```

Install the CLI globally:

```sh
sudo make install     # -> /usr/local/bin/vigil
sudo make uninstall
```

Release builds (Developer ID + hardened runtime + Sparkle keys) are CI-only; see `RELEASING.md`. Forks cannot run the release workflow because secrets are not shared with pull-request runs.

## Safety

Closed-lid operation can trap heat. Keep the machine ventilated and prefer AC power. By default, `vigil on` refuses to enable while running on battery power; pass `--force-battery` to override.

If you previously installed an old dev build of Vigil with the `dev.local.vigil` bundle id, run `Scripts/uninstall-legacy.sh` once before installing v0.1.0 to clear orphaned LaunchAgents, helper paths, and sudoers entries.

## License

MIT. See [LICENSE](LICENSE).
