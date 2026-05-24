# Vigil — build, sign, notarize, release
#
# Local-only release flow (signed + notarized on the developer's Mac).
#
# Common targets:
#   make app                                — ad-hoc signed local build for dev/testing
#   make signing-doctor                     — print available Developer ID identities
#   make signing-setup                      — store Apple ID + app-specific password in keychain
#   make release VERSION=X.Y.Z              — full pipeline: build → sign → notarize → staple
#                                              → zip → appcast → GitHub Release upload
#   make release VERSION=X.Y.Z PUBLISH=false — same, but stop after notarizing locally

# Load .env.signing if present (Make syntax — see .env.signing.example).
-include .env.signing

.PHONY: build icon app release release-bundle notarize staple package-zip appcast \
        gh-release gh-publish signing-doctor signing-setup \
        install uninstall status on off doctor verify clean \
        _generate_version _assemble _inject_version _inject_sparkle _trim_sparkle \
        _sign_dev _sign_release _require-release-env _ensure-sparkle-public-key

# ---- Configuration ----------------------------------------------------------

APP_NAME           := Vigil
BUNDLE_ID          := com.vigil.app
PREFIX             ?= /usr/local

# Version source of truth: caller-injected. Defaults are a recognisable dev marker.
VERSION            ?= 0.0.0-dev
BUILD              ?= 1

# Codesigning. Loaded from .env.signing for `make release`; ad-hoc for `make app`.
CODESIGN_IDENTITY  ?= -

# Notarization profile. Stored in login keychain via `make signing-setup`.
APPLE_KEYCHAIN_PROFILE ?= vigil

# Sparkle (both must be set for the updater to activate at runtime —
# see Sources/VigilMenuBar/main.swift configurationIsPresent).
SPARKLE_FEED_URL       ?= https://github.com/dbuskariol/vigil/releases/latest/download/appcast.xml
SPARKLE_PUBLIC_ED_KEY  ?=

# GitHub Release publishing
GH_REPO            := dbuskariol/vigil
PUBLISH            ?= true
RELEASE_NOTES_FILE ?= releases/notes/$(VERSION).md

# Build artefacts
BUILD_DIR          := .build/release
CLI_BIN            := $(BUILD_DIR)/vigil
APP_BIN            := $(BUILD_DIR)/VigilMenuBar
SPARKLE_FRAMEWORK  := $(BUILD_DIR)/Sparkle.framework
SPARKLE_BIN_DIR    := .build/artifacts/sparkle/Sparkle/bin

APP_BUNDLE         := dist/$(APP_NAME).app
APP_CONTENTS       := $(APP_BUNDLE)/Contents
APP_MACOS          := $(APP_CONTENTS)/MacOS
APP_RESOURCES      := $(APP_CONTENTS)/Resources
APP_FRAMEWORKS     := $(APP_CONTENTS)/Frameworks

ENT_APP            := App/Vigil.entitlements
ENT_HELPER         := App/Helper.entitlements

DIST_DIR           := dist
RELEASE_ZIP        := $(DIST_DIR)/$(APP_NAME)-$(VERSION).zip
NOTARY_ZIP         := $(DIST_DIR)/$(APP_NAME)-notary.zip
APPCAST_DIR        := $(DIST_DIR)/appcast-input
RELEASE_NOTES_HTML := $(DIST_DIR)/releaseNotes-$(VERSION).html

# ---- Top-level targets ------------------------------------------------------

build:
	swift build -c release

icon:
	swift Scripts/make_app_icon.swift

# Local ad-hoc dev build.
app: build icon _assemble _trim_sparkle _inject_version _inject_sparkle _sign_dev

# Full local release pipeline.
# Sequenced via sub-makes so `_generate_version` regenerates Version.swift
# before `swift build` sees it (the bundled CLI bakes the version in for the
# menu-app's helper-version-mismatch handshake).
release: icon
	$(MAKE) _require-release-env _ensure-sparkle-public-key
	$(MAKE) _generate_version
	$(MAKE) build
	$(MAKE) release-bundle
	$(MAKE) notarize
	$(MAKE) staple
	$(MAKE) package-zip
	$(MAKE) appcast
	@if [ "$(PUBLISH)" = "true" ]; then \
		$(MAKE) gh-release gh-publish; \
		echo; \
		echo "✓ Published https://github.com/$(GH_REPO)/releases/tag/v$(VERSION)"; \
	else \
		echo; \
		echo "✓ Local release artefacts ready in $(DIST_DIR). Set PUBLISH=true to upload."; \
	fi

release-bundle: _assemble _trim_sparkle _inject_version _inject_sparkle _sign_release verify

# ---- Apple credentials ------------------------------------------------------

# Print Developer ID identities and check the notary profile.
signing-doctor:
	@echo "=== Code signing identities ==="
	@security find-identity -v -p codesigning
	@echo
	@echo "=== Active CODESIGN_IDENTITY (.env.signing or env) ==="
	@echo "  $(CODESIGN_IDENTITY)"
	@echo
	@echo "=== APPLE_KEYCHAIN_PROFILE ==="
	@echo "  $(APPLE_KEYCHAIN_PROFILE)"
	@echo
	@echo "Validate the profile works with: xcrun notarytool history --keychain-profile '$(APPLE_KEYCHAIN_PROFILE)'"

# One-time: store the Apple ID + app-specific password in the login keychain
# under APPLE_KEYCHAIN_PROFILE (default: vigil-notary). After this, the password
# never needs to be typed or env-var'd again.
signing-setup:
	@if [ -z "$(APPLE_ID)" ] || [ -z "$(APPLE_APP_SPECIFIC_PASSWORD)" ] || [ -z "$(APPLE_TEAM_ID)" ]; then \
		echo "ERROR: signing-setup needs APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD + APPLE_TEAM_ID in .env.signing."; \
		echo "(Copy .env.signing.example to .env.signing, fill them in, then re-run.)"; \
		exit 1; \
	fi
	@xcrun notarytool store-credentials "$(APPLE_KEYCHAIN_PROFILE)" \
		--apple-id "$(APPLE_ID)" \
		--team-id "$(APPLE_TEAM_ID)" \
		--password "$(APPLE_APP_SPECIFIC_PASSWORD)"
	@echo
	@echo "✓ Stored. You can now remove APPLE_ID / APPLE_APP_SPECIFIC_PASSWORD / APPLE_TEAM_ID from .env.signing."

# ---- Pipeline stages --------------------------------------------------------

_require-release-env:
	@if [ "$(CODESIGN_IDENTITY)" = "-" ] || [ -z "$(CODESIGN_IDENTITY)" ]; then \
		echo "ERROR: release requires CODESIGN_IDENTITY=\"Developer ID Application: …\""; \
		echo "Set it in .env.signing (copy .env.signing.example to start)."; \
		exit 1; \
	fi
	@if [ -z "$(VERSION)" ] || [ "$(VERSION)" = "0.0.0-dev" ]; then \
		echo "ERROR: release requires VERSION=X.Y.Z (e.g. 0.1.0 or 0.1.0-beta.1)"; \
		exit 1; \
	fi
	@if [ ! -f "$(RELEASE_NOTES_FILE)" ]; then \
		echo "ERROR: release notes missing: $(RELEASE_NOTES_FILE)"; \
		exit 1; \
	fi

# If SPARKLE_PUBLIC_ED_KEY wasn't passed in, read it from the keychain entry
# that Sparkle's generate_keys created.
_ensure-sparkle-public-key:
	@if [ -z "$(SPARKLE_PUBLIC_ED_KEY)" ]; then \
		if [ ! -x "$(SPARKLE_BIN_DIR)/generate_keys" ]; then \
			swift package resolve >/dev/null; \
		fi; \
		KEY=$$("$(SPARKLE_BIN_DIR)/generate_keys" -p 2>/dev/null); \
		if [ -z "$$KEY" ]; then \
			echo "ERROR: cannot find Sparkle public key. Run 'make signing-doctor' or generate_keys."; \
			exit 1; \
		fi; \
		echo "$$KEY" > $(DIST_DIR)/.sparkle-public-key; \
	fi
	@mkdir -p $(DIST_DIR)

# Bake the BUILD value into a Swift constant so the standalone privileged-helper
# binary (which has no Info.plist nearby) can report its own version for the
# menu-app's helper-version-mismatch handshake. Only runs for `make release`;
# `make app` keeps the checked-in default so the working tree stays clean.
_generate_version:
	@printf '// Generated by Makefile. Edits will be overwritten.\npublic enum VigilVersion {\n    public static let value = "%s"\n}\n' "$(BUILD)" > Sources/VigilIdentifiers/Version.swift

_assemble:
	rm -rf "$(APP_BUNDLE)"
	install -d "$(APP_MACOS)" "$(APP_RESOURCES)" "$(APP_FRAMEWORKS)"
	install "App/Info.plist"   "$(APP_CONTENTS)/Info.plist"
	install "$(APP_BIN)"       "$(APP_MACOS)/$(APP_NAME)"
	install "$(CLI_BIN)"       "$(APP_RESOURCES)/vigil"
	install "App/AppIcon.icns" "$(APP_RESOURCES)/AppIcon.icns"
	ditto   "$(SPARKLE_FRAMEWORK)" "$(APP_FRAMEWORKS)/Sparkle.framework"
	install_name_tool -add_rpath "@executable_path/../Frameworks" \
		"$(APP_MACOS)/$(APP_NAME)" 2>/dev/null || true

# Sparkle 2 only needs the bundled XPC services when the host app is sandboxed.
# Vigil is intentionally non-sandboxed; remove them to shrink the signing surface.
# https://sparkle-project.org/documentation/sandboxing/
_trim_sparkle:
	rm -rf "$(APP_FRAMEWORKS)/Sparkle.framework/Versions/B/XPCServices"
	rm -f  "$(APP_FRAMEWORKS)/Sparkle.framework/XPCServices"

_inject_version:
	plutil -replace CFBundleIdentifier         -string  "$(BUNDLE_ID)" "$(APP_CONTENTS)/Info.plist"
	plutil -replace CFBundleShortVersionString -string  "$(VERSION)"   "$(APP_CONTENTS)/Info.plist"
	plutil -replace CFBundleVersion            -string  "$(BUILD)"     "$(APP_CONTENTS)/Info.plist"

# Inject SUFeedURL and SUPublicEDKey. Pulls the public key from the file written
# by _ensure-sparkle-public-key if SPARKLE_PUBLIC_ED_KEY wasn't passed in.
_inject_sparkle:
	@KEY="$(SPARKLE_PUBLIC_ED_KEY)"; \
	if [ -z "$$KEY" ] && [ -f $(DIST_DIR)/.sparkle-public-key ]; then \
		KEY="$$(cat $(DIST_DIR)/.sparkle-public-key)"; \
	fi; \
	if [ -n "$(SPARKLE_FEED_URL)" ] && [ -n "$$KEY" ]; then \
		plutil -replace SUFeedURL     -string "$(SPARKLE_FEED_URL)" "$(APP_CONTENTS)/Info.plist" 2>/dev/null \
		  || plutil -insert SUFeedURL -string "$(SPARKLE_FEED_URL)" "$(APP_CONTENTS)/Info.plist"; \
		plutil -replace SUPublicEDKey   -string "$$KEY" "$(APP_CONTENTS)/Info.plist" 2>/dev/null \
		  || plutil -insert SUPublicEDKey -string "$$KEY" "$(APP_CONTENTS)/Info.plist"; \
	fi

# Ad-hoc sign: single pass is fine for local dev. No hardened runtime, no timestamp.
_sign_dev:
	codesign --force --sign - "$(APP_BUNDLE)"

# Inside-out sign for release: nested Mach-Os first, then the framework,
# then the embedded CLI with its entitlements, then the outer app last.
# Each step requires --options runtime and --timestamp for notarization.
_sign_release:
	@set -e; \
	FLAGS="--force --options runtime --timestamp --sign \"$(CODESIGN_IDENTITY)\""; \
	eval codesign $$FLAGS \"$(APP_FRAMEWORKS)/Sparkle.framework/Versions/B/Updater.app\"; \
	eval codesign $$FLAGS \"$(APP_FRAMEWORKS)/Sparkle.framework/Versions/B/Autoupdate\"; \
	if [ -e "$(APP_FRAMEWORKS)/Sparkle.framework/Versions/B/Resources/fileop" ]; then \
		eval codesign $$FLAGS \"$(APP_FRAMEWORKS)/Sparkle.framework/Versions/B/Resources/fileop\"; \
	fi; \
	eval codesign $$FLAGS \"$(APP_FRAMEWORKS)/Sparkle.framework\"; \
	eval codesign $$FLAGS --entitlements "$(ENT_HELPER)" \"$(APP_RESOURCES)/vigil\"; \
	eval codesign $$FLAGS --entitlements "$(ENT_APP)"    \"$(APP_BUNDLE)\"

verify:
	codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"
	codesign -dvv "$(APP_BUNDLE)" 2>&1 | grep -E 'Authority|TeamIdentifier|Identifier'

notarize:
	rm -f "$(NOTARY_ZIP)"
	ditto -c -k --sequesterRsrc --keepParent "$(APP_BUNDLE)" "$(NOTARY_ZIP)"
	xcrun notarytool submit "$(NOTARY_ZIP)" \
		--keychain-profile "$(APPLE_KEYCHAIN_PROFILE)" \
		--wait --timeout 30m
	rm -f "$(NOTARY_ZIP)"

staple:
	xcrun stapler staple "$(APP_BUNDLE)"
	xcrun stapler validate "$(APP_BUNDLE)"
	spctl --assess --type execute --verbose=4 "$(APP_BUNDLE)"

package-zip:
	rm -f "$(RELEASE_ZIP)"
	ditto -c -k --sequesterRsrc --keepParent "$(APP_BUNDLE)" "$(RELEASE_ZIP)"
	@echo "Release zip: $(RELEASE_ZIP)"

# Render release notes Markdown to HTML for Sparkle, then hydrate prior release
# zips (so generate_appcast builds a multi-entry feed) and generate appcast.xml.
appcast:
	@command -v gh >/dev/null || { echo "ERROR: gh CLI required for release notes + asset hydration"; exit 1; }
	@jq --arg text "$$(cat $(RELEASE_NOTES_FILE))" -n '{text:$$text}' \
		| gh api -X POST /markdown --input - --hostname github.com \
		> "$(RELEASE_NOTES_HTML)"
	@rm -rf "$(APPCAST_DIR)"
	@mkdir -p "$(APPCAST_DIR)"
	@if gh release list --repo "$(GH_REPO)" --exclude-drafts --limit 20 --json tagName --jq '.[].tagName' >/dev/null 2>&1; then \
		gh release list --repo "$(GH_REPO)" --exclude-drafts --limit 20 --json tagName --jq '.[].tagName' \
			| while read -r tag; do \
				gh release download "$$tag" --repo "$(GH_REPO)" \
					--pattern 'Vigil-*.zip' \
					--pattern 'releaseNotes-*.html' \
					--dir "$(APPCAST_DIR)" 2>/dev/null || true; \
			done; \
	fi
	cp "$(RELEASE_ZIP)" "$(RELEASE_NOTES_HTML)" "$(APPCAST_DIR)/"
	"$(SPARKLE_BIN_DIR)/generate_appcast" \
		--download-url-prefix "https://github.com/$(GH_REPO)/releases/download/v$(VERSION)/" \
		--link "https://github.com/$(GH_REPO)" \
		--maximum-versions 10 \
		"$(APPCAST_DIR)"
	cp "$(APPCAST_DIR)/appcast.xml" "$(DIST_DIR)/appcast.xml"
	@echo "Appcast: $(DIST_DIR)/appcast.xml"

# Creates the GitHub release as a draft so an upload failure mid-flight doesn't
# leave a half-public release. SemVer pre-release identifiers (anything after `-`,
# e.g. 0.1.0-beta.1) get `--prerelease`, keeping them out of /latest/.
gh-release:
	@command -v gh >/dev/null || { echo "ERROR: gh CLI required"; exit 1; }
	@PRE=""; case "$(VERSION)" in *-*) PRE="--prerelease" ;; esac; \
	gh release delete "v$(VERSION)" --repo "$(GH_REPO)" --yes --cleanup-tag 2>/dev/null || true; \
	ASSETS=("$(RELEASE_ZIP)" "$(RELEASE_NOTES_HTML)" "$(DIST_DIR)/appcast.xml"); \
	for z in $(APPCAST_DIR)/Vigil-*.zip; do \
		base="$$(basename "$$z")"; \
		[ "$$base" != "Vigil-$(VERSION).zip" ] && ASSETS+=("$$z"); \
	done; \
	for h in $(APPCAST_DIR)/releaseNotes-*.html; do \
		base="$$(basename "$$h")"; \
		[ "$$base" != "releaseNotes-$(VERSION).html" ] && ASSETS+=("$$h"); \
	done; \
	gh release create "v$(VERSION)" \
		--repo "$(GH_REPO)" \
		--draft $$PRE \
		--title "v$(VERSION)" \
		--notes-file "$(RELEASE_NOTES_FILE)" \
		"$${ASSETS[@]}"

gh-publish:
	gh release edit "v$(VERSION)" --repo "$(GH_REPO)" --draft=false

# ---- CLI install ------------------------------------------------------------

install: build
	install -d "$(PREFIX)/bin"
	install "$(CLI_BIN)" "$(PREFIX)/bin/vigil"

uninstall:
	rm -f "$(PREFIX)/bin/vigil"

status: ; swift run vigil status
on:     ; swift run vigil on
off:    ; swift run vigil off
doctor: ; swift run vigil doctor

clean:
	rm -rf .build dist App/AppIcon.icns App/AppIcon.iconset
