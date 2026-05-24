# Releasing Vigil

Vigil is signed and notarized **locally** on the maintainer's Mac, then pushed to GitHub Releases. No CI secrets, no `.p12` base64 dance — just your existing Developer ID cert in the login keychain and one app-specific password stored once.

## One-time setup

1. **Generate the Sparkle EdDSA key.** (Skip if already done — check `make signing-doctor`.)
   ```sh
   swift package resolve
   .build/artifacts/sparkle/Sparkle/bin/generate_keys
   ```
   Private key lands in your login keychain (`https://sparkle-project.org` / `ed25519`). Public key is printed to stdout. **Back up the private key offline** — 1Password or hardware key. Lose it and no existing Vigil install can ever auto-update.

2. **Create `.env.signing` from the template.**
   ```sh
   cp .env.signing.example .env.signing
   ```
   Fill in `CODESIGN_IDENTITY` (your Developer ID) and uncomment the three `APPLE_*` lines (Apple ID email, app-specific password from https://appleid.apple.com → App-Specific Passwords, Team ID).

3. **Store the app-specific password in your keychain via notarytool:**
   ```sh
   make signing-setup
   ```
   This calls `xcrun notarytool store-credentials vigil-notary` under the hood. After it succeeds, comment out the `APPLE_ID` / `APPLE_APP_SPECIFIC_PASSWORD` / `APPLE_TEAM_ID` lines in `.env.signing` — the password lives in your keychain now.

4. **Sanity check:**
   ```sh
   make signing-doctor
   ```
   Should print your Developer ID identity and confirm the keychain profile.

## Per-release

1. Write release notes for the next version: `releases/notes/X.Y.Z.md` (GitHub-flavoured Markdown).
2. Commit them.
3. Cut the release:
   ```sh
   make release VERSION=0.1.0-beta.1 BUILD=1
   ```
   The pipeline runs: build → sign (inside-out) → notarize via Apple → staple → zip → render release notes HTML via `gh api /markdown` → hydrate prior release zips → generate Sparkle appcast → create GitHub draft release → upload all assets → publish.

   SemVer pre-release tags (anything after `-`, e.g. `0.1.0-beta.1`) are flagged as prereleases on GitHub so they don't pollute `releases/latest/download/appcast.xml`.

4. The whole pipeline takes ~5-10 min (Apple's notarization is the slow part — usually 2-5 min).

5. **Optionally tag the commit afterwards.** The release flow does not depend on a git tag:
   ```sh
   git tag -a v0.1.0-beta.1 -m "v0.1.0-beta.1"
   git push --tags
   ```

## Versioning rules

- `CFBundleShortVersionString` (human version) = the `VERSION` argument you pass.
- `CFBundleVersion` (Sparkle's ordering key) = the `BUILD` argument. **Must strictly increase** between releases or Sparkle will silently refuse the update. Either bump it manually (`BUILD=2`, `BUILD=3`, ...) or use `BUILD=$(date +%s)` for a monotonic timestamp.

## Dry-run / local-only

Skip the GitHub upload to test the pipeline:
```sh
make release VERSION=0.1.0-beta.1 BUILD=99 PUBLISH=false
```
Artefacts land in `dist/`:
- `Vigil-0.1.0-beta.1.zip` — stapled, notarized
- `appcast.xml` — EdDSA-signed
- `releaseNotes-0.1.0-beta.1.html`

## Re-cutting a failed release

If something blew up mid-pipeline, just re-run `make release VERSION=…`. The `gh-release` step deletes any stale draft for the same tag before recreating.

## What `.env.signing` contains

| Variable | Purpose |
|---|---|
| `CODESIGN_IDENTITY` | Full string — `Developer ID Application: Name (TEAMID)` |
| `APPLE_KEYCHAIN_PROFILE` | Name under which notarytool stores credentials (default `vigil-notary`) |
| `APPLE_ID` / `APPLE_APP_SPECIFIC_PASSWORD` / `APPLE_TEAM_ID` | Only needed for `make signing-setup`; can be removed after |

`.env.signing` is gitignored. Never commit it.
