# Contributing to Vigil

Vigil is a small personal utility. Contributions are welcome but the surface area is intentionally tight.

## Building locally

```sh
make app
open dist/Vigil.app
```

Local builds are ad-hoc signed. Sparkle stays inert because no `SUFeedURL`/`SUPublicEDKey` are injected.

The release build path (`make release VERSION=…`) requires a Developer ID identity, the Sparkle EdDSA private key, and an App Store Connect API key. Forks cannot run the release workflow — the secrets are not shared with pull-request runs.

## Pull requests

- Run `swift build -c release` and `make app` locally before opening the PR.
- Keep changes scoped. Identifier constants live in `Sources/VigilIdentifiers/`; do not duplicate them.
- Touching anything in the elevation paths (`Sources/vigil/main.swift` install / sudoers / helper logic, or the AppleScript `do shell script with administrator privileges` flow in `Sources/VigilMenuBar/main.swift`) gets extra scrutiny — the threat model is described in `README.md` under "Trust model".

## Releasing

Maintainers only. See `RELEASING.md`.
