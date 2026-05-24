# Releasing Vigil

## One-time setup

1. **Generate the Sparkle EdDSA key.**
   ```sh
   swift package resolve
   .build/artifacts/sparkle/Sparkle/bin/generate_keys
   ```
   The private key is stored in the login keychain (`https://sparkle-project.org` / `ed25519`). The public key is printed to stdout.

2. **Mirror the keys to GitHub secrets.**
   ```sh
   .build/artifacts/sparkle/Sparkle/bin/generate_keys -p \
     | tr -d '\n' | gh secret set SPARKLE_PUBLIC_ED_KEY --repo dbuskariol/vigil
   .build/artifacts/sparkle/Sparkle/bin/generate_keys -x /dev/stdout \
     | gh secret set SPARKLE_PRIVATE_KEY --repo dbuskariol/vigil
   ```
   `-x /dev/stdout` keeps the private key out of the filesystem entirely (APFS copy-on-write makes `rm -P` ineffective for true secure deletion).

3. **Back up the EdDSA private key offline.** 1Password / hardware key. If it's ever lost, no existing Vigil install will auto-update again; users must manually re-download. There is no recovery short of shipping a new app with a new public key.

4. **Export Developer ID Application cert + private key as .p12.**
   In Keychain Access, find `Developer ID Application: Daniel Buskariol (BJCVJ5G7MJ)`, select both the cert and the linked private key, right-click → Export Items, set a strong password. Then:
   ```sh
   base64 -i cert.p12 | gh secret set DEVELOPER_ID_APPLICATION_P12_BASE64 --repo dbuskariol/vigil
   gh secret set DEVELOPER_ID_APPLICATION_P12_PASSWORD --repo dbuskariol/vigil   # paste the password
   rm cert.p12
   ```

5. **Issue an App Store Connect API key** for notarization (App Store Connect → Users and Access → Integrations → Team Keys → +). Role: `Developer` is sufficient. The `.p8` can only be downloaded once; store carefully.
   ```sh
   gh secret set APPSTORE_CONNECT_API_KEY_ID --repo dbuskariol/vigil          # 10-char key id
   gh secret set APPSTORE_CONNECT_API_KEY_ISSUER_ID --repo dbuskariol/vigil   # UUID
   base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set APPSTORE_CONNECT_API_KEY_P8_BASE64 --repo dbuskariol/vigil
   ```

## Per-release

1. Write `releases/notes/X.Y.Z.md` (GitHub-flavoured Markdown; rendered to HTML in CI via `gh api /markdown`).
2. Commit it.
3. Tag and push:
   ```sh
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push --tags
   ```
4. Watch the `release` workflow run. It builds, signs, notarizes, staples, generates the appcast, creates a draft release with all assets attached, then publishes it.
5. If the workflow fails after creating the draft, re-running the tag is safe — the workflow deletes any stale draft for the same tag before creating a new one.

Versioning rules:
- `CFBundleShortVersionString` (the human version) comes from the tag (`v0.2.0` → `0.2.0`).
- `CFBundleVersion` (Sparkle's ordering key) comes from `github.run_number` — strictly monotonic across workflow runs, independent of git history. Force-pushes / soft-resets do not affect it.

## Manual / re-run release

`workflow_dispatch` accepts a `version` input (without leading `v`). Use it to re-cut a release after fixing CI without re-tagging.

## Local notarized dry-run (optional)

For practising the full release path outside CI:

```sh
xcrun notarytool store-credentials vigil-notary \
  --key ~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8 \
  --key-id XXXXXXXXXX \
  --issuer YYYYYYYY-YYYY-YYYY-YYYY-YYYYYYYYYYYY

make release \
  VERSION=0.2.0 BUILD=$(date +%s) \
  CODESIGN_IDENTITY="Developer ID Application: Daniel Buskariol (BJCVJ5G7MJ)" \
  SPARKLE_FEED_URL="https://github.com/dbuskariol/vigil/releases/latest/download/appcast.xml" \
  SPARKLE_PUBLIC_ED_KEY="$(.build/artifacts/sparkle/Sparkle/bin/generate_keys -p)"

ditto -c -k --sequesterRsrc --keepParent dist/Vigil.app dist/Vigil-notary.zip
xcrun notarytool submit dist/Vigil-notary.zip --keychain-profile vigil-notary --wait --timeout 30m
xcrun stapler staple dist/Vigil.app
ditto -c -k --sequesterRsrc --keepParent dist/Vigil.app dist/Vigil-0.2.0.zip
```

Don't push the resulting zip; it's just a dry-run.
