# Vigil

> A macOS menu-bar app and CLI that keeps a Mac awake on demand. Two features, one app: keep the display + system awake while you're at it, or keep the machine fully awake with the lid closed for unattended long jobs.

<img width="446" height="746" alt="image" src="https://github.com/user-attachments/assets/a88d3c97-b286-4cb2-9e25-54b129c66182" />


<img width="421" height="461" alt="image" src="https://github.com/user-attachments/assets/25a32db3-f025-42d1-9dc2-1c33a54e53d6" />

## Features

- **Caffeinate** — holds two IOKit power assertions (`PreventUserIdleSystemSleep` + `PreventUserIdleDisplaySleep`) to keep the display and system from idling to sleep. No `pmset`, no root, no privileged helper. Manual Apple-menu Sleep and lid close still send the Mac to sleep — by design.

- **Lid-Awake** — applies a reversible `pmset` profile (`disablesleep=1`, `sleep=0`, `disksleep=0`, `ttyskeepawake=1`, `tcpkeepalive=1`) and holds three IOKit power assertions including `PreventSystemSleep`. Keeps the Mac fully awake with the lid closed. Refuses to enable on battery without explicit confirmation. Requires one-time administrator approval (**Approve All**) to time-limit cleanly.

Both features have a shared **time-limit dropdown** with eight presets: Indefinitely, 5 minutes, 10 minutes, 15 minutes, 30 minutes, 1 hour, 2 hours, 5 hours. When a timed session reaches its deadline the feature auto-disables and the system returns to its previous behaviour.

## Install

1. Download `Vigil-X.Y.Z.dmg` from [the latest release](https://github.com/dbuskariol/vigil/releases/latest).
2. Open the DMG and drag `Vigil.app` to the `Applications` shortcut inside it.
3. Open `Vigil.app` from `/Applications`. The menu-bar icon appears at the right of the status bar.

(If you instead use the `.zip` artefact: unzip it and drag `Vigil.app` to `/Applications` **before opening it**. macOS Gatekeeper translocates apps launched from `~/Downloads` to a randomised quarantine path; Vigil refuses to enable while translocated.)

Auto-updates check daily via Sparkle 2 with EdDSA signature verification. You can disable them in the Sparkle preferences dialog.

## Use

From the menu bar:

- Click the icon to open the popover with two feature cards.
- Each card has its own toggle, duration dropdown, live countdown when armed with a timer, and an opt-in **Notify when timer ends** checkbox.
- The **Approve All** banner (inside the Lid-Awake card) installs a scoped privileged helper so Lid-Awake can run without repeated password prompts. **Caffeinate works without approval.**
- Click the small footer **stop.circle** button to turn off both features at once.
- The Diagnostics disclosure (collapsed by default) shows the power source, lid state, battery, displays, keyboard backlight API status, and helper version.
- Quitting Vigil leaves active features running in the background — both features are persistent user LaunchAgents. The Quit button's tooltip says so when something's active.

From the CLI (after `make install`):

```sh
vigil status                              # human-readable status
vigil status --json                       # machine-readable status
vigil doctor                              # JSON + verbose human diagnostics
vigil caffeinate on                       # indefinite caffeinate
vigil caffeinate on --duration 1h         # 1-hour caffeinate
vigil caffeinate off
vigil lid-awake on --duration 2h          # 2-hour lid-closed-awake
vigil lid-awake off
vigil approve-all
vigil approval-status
```

`<duration>` is one of `indefinite | 5m | 10m | 15m | 30m | 1h | 2h | 5h`. Default: `indefinite`.

### What enable / disable actually do

Enabling **Lid-Awake** snapshots the current `pmset` profile, runs `pmset -a disablesleep 1 sleep 0 disksleep 0 ttyskeepawake 1 tcpkeepalive 1`, writes `~/Library/Application Support/Vigil/state-lid-awake.json`, touches `~/Library/Application Support/Vigil/sentinel-lid-awake`, installs `~/Library/LaunchAgents/com.vigil.app.lid-awake.plist`, and bootstraps it. The agent runs `vigil hold lid-awake --approved-helper`, which holds three IOKit assertions and polls lid state once per second so it can dim the display and keyboard backlight when the lid closes (configurable via the visual-options toggles on the Lid-Awake card).

Disabling Lid-Awake (or hitting its timer deadline) restores the saved `pmset` profile, removes the sentinel and session files, and tears down the LaunchAgent.

Enabling **Caffeinate** writes `~/Library/Application Support/Vigil/state-caffeinate.json`, touches `~/Library/Application Support/Vigil/sentinel-caffeinate`, installs `~/Library/LaunchAgents/com.vigil.app.caffeinate.plist`, and bootstraps it. The agent runs `vigil hold caffeinate`, which holds two IOKit assertions. No `pmset`, no privileges, no helper.

Disabling Caffeinate removes the sentinel and session files, and tears down the LaunchAgent.

### Login Items

Both feature LaunchAgents associate with `com.vigil.app`, so macOS System Settings → General → Login Items shows **one** "Vigil" entry that toggles both background agents together. The per-feature on/off lives in the Vigil popover; the System Settings toggle is the user-visible escape hatch.

## How it works

Vigil is structured as three Mach-Os: the SwiftUI **menu app** (`VigilMenuBar`), the **CLI** (`vigil`, embedded in `Vigil.app/Contents/Resources/vigil`), and on demand a root-owned copy of that same CLI at `/Library/PrivilegedHelperTools/com.vigil.app.helper`.

The menu app does not hold IOKit assertions itself. It is a pure controller: it shells out to the bundled CLI for every action, and decodes `vigil status --json` for every read. Active features survive menu-app quit because the assertions are held by per-feature **user LaunchAgents** that launchd keeps alive while a per-feature sentinel file exists.

Vigil also reads private IOKit power-domain state for diagnostics (`SleepDisabled`, `AppleClamshellState`, `AppleClamshellCausesSleep`) and uses private Apple APIs (`CoreDisplay`, `DisplayServices`, `CoreBrightness`) for display / keyboard backlight control during Lid-Awake. This design is intentionally not App Store-safe. The goal is reliable awake-on-demand operation, not Apple review.

For the full design rationale see [`docs/0.2.0-design.md`](docs/0.2.0-design.md).

## Trust model

Vigil takes administrator privileges in two ways, both **only for Lid-Awake** (Caffeinate uses no privileged ops):

1. **One-time `Approve All` flow.** The menu app runs `do shell script with administrator privileges` (`NSAppleScript` + macOS SecurityAgent). The privileged shell installs the `vigil` CLI to `/Library/PrivilegedHelperTools/com.vigil.app.helper` (root-owned, `0755`) and writes a sudoers drop-in at `/etc/sudoers.d/vigil-<uid>` (root-owned, `0440`, validated with `visudo -cf`). The sudoers rule is intentionally narrow:

   ```
   <user> ALL=(root) NOPASSWD: /Library/PrivilegedHelperTools/com.vigil.app.helper privileged-pmset-batch *, /Library/PrivilegedHelperTools/com.vigil.app.helper approval-status, /Library/PrivilegedHelperTools/com.vigil.app.helper privileged-version, /Library/PrivilegedHelperTools/com.vigil.app.helper privileged-ipc-version
   ```

   Four verbs only: a `pmset` batch (with an in-binary allowlist of `disablesleep`, `sleep`, `disksleep`, `ttyskeepawake`, `tcpkeepalive`), an `approval-status` probe, a `privileged-version` probe, and a `privileged-ipc-version` probe used for IPC-contract handshake. The allowlist is enforced inside the helper (see `Sources/vigil/Privilege.swift`'s `argumentsAreAllowedPMSetBatch`), so the `privileged-pmset-batch *` sudoers entry is still bounded.

   **Time-limited Lid-Awake requires approval** so that when the timer expires the agent can restore the saved `pmset` profile non-interactively. Indefinite Lid-Awake still works without approval — the user disables it manually via the standard administrator-password sheet.

2. **Ad-hoc `do shell script` prompt** when `Approve All` has not been run yet. Each Lid-Awake on/off shows the standard macOS administrator-password sheet.

**Caffeinate uses neither.** `IOPMAssertionCreateWithName` is unprivileged.

Auto-updates land via Sparkle 2 from a stable URL: `https://github.com/dbuskariol/vigil/releases/latest/download/appcast.xml`. The appcast is EdDSA-signed; the public key is baked into `Info.plist` (`SUPublicEDKey`). Sparkle refuses to install any update whose signature doesn't verify.

After a Sparkle update, Vigil's menu app probes the helper's IPC contract version against the version this build of the menu app expects. They are only re-prompted to re-approve when the privileged IPC contract surface actually changes (sudoers verbs added/removed, in-binary `pmset` allowlist changed, or `privileged-pmset-batch` wire format changed) — NOT on every routine bug-fix release. Both feature LaunchAgents are also booted out before the install (so the new CLI Mach-O can replace the old in place) and re-bootstrapped automatically on relaunch for any feature whose session is still within its window.

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

Release builds (Developer ID + hardened runtime + Sparkle keys) are maintainer-only; see `RELEASING.md`.

## Safety

Closed-lid Lid-Awake operation can trap heat. Keep the machine ventilated and prefer AC power. By default, `vigil lid-awake on` refuses to enable while running on battery power; pass `--force-battery` to override (or click **Turn On** a second time in the menu app to confirm).

## License

MIT. See [LICENSE](LICENSE).
