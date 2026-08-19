# Single local entry point for the acceptance / backend-contract tiers (AC-4):
# the same fixtures and tests CI runs, no CI-only wiring.
#
#   make backend-contract BACKEND=classic   # bring up Classic, run the tier, tear down
#   make backend-contract BACKEND=ocis       # same for oCIS
#   make unit                                # the pure-unit swift test run
#   make up   BACKEND=classic|ocis           # just start a fixture
#   make down BACKEND=classic|ocis           # just stop it
#   make install                             # build + sign the app, install to ~/Applications
#   make icons                               # regenerate the app icon from the ownCloud logo
#   make dmg VERSION=1.2.0 BUILD=1           # build the signed release .dmg
#   make notarize                            # notarize + staple it (needs an ASC key)
#   make release-version-test                # self-test the tag -> version parser
#
# BACKEND selects the fixture; it defaults to classic.

BACKEND ?= classic
COMPOSE  = docker compose -f test/fixtures/$(BACKEND)/docker-compose.yml

# Local install for the Task 6.0 spike. The extension is only discovered when the
# containing app lives in an Applications folder, so a signed Debug build is copied
# there. Defaults to ~/Applications (no elevation needed); set INSTALL_DIR=/Applications
# to install system-wide (requires sudo/admin — cp there is not permitted otherwise).
APP_NAME     = ownCloud File Provider.app
DERIVED_DATA = build
BUILT_APP    = $(DERIVED_DATA)/Build/Products/Debug/$(APP_NAME)
INSTALL_DIR  ?= $(HOME)/Applications
INSTALLED_APP = $(INSTALL_DIR)/$(APP_NAME)

.PHONY: unit backend-contract up down wait clean install icons dmg notarize release-version-test

unit:
	cd Core && swift test

# Bring the fixture up, wait for health, run the contract tier against it, then
# tear it down even if the tests fail.
backend-contract: up wait
	( cd Core && OWNCLOUD_TEST_BACKEND=$(BACKEND) swift test --filter BackendContract ); \
	status=$$?; $(MAKE) down BACKEND=$(BACKEND); exit $$status

up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down -v

# Poll the backend's API until it authenticates, so tests never race startup.
wait:
	@echo "Waiting for $(BACKEND) to become ready…"
	@if [ "$(BACKEND)" = "ocis" ]; then \
		url="https://localhost:9200/graph/v1.0/me/drives"; insecure="-k"; \
	else \
		url="http://localhost:8080/status.php"; insecure=""; \
	fi; \
	for i in $$(seq 1 40); do \
		code=$$(curl -s $$insecure -u admin:admin -o /dev/null -w "%{http_code}" $$url); \
		if [ "$$code" = "200" ] || [ "$$code" = "207" ]; then echo "ready ($$code)"; exit 0; fi; \
		sleep 3; \
	done; \
	echo "timed out waiting for $(BACKEND)"; exit 1

clean:
	-$(MAKE) down BACKEND=classic
	-$(MAKE) down BACKEND=ocis

# Regenerate Resources/Assets.xcassets/AppIcon.appiconset from the committed
# ownCloud logo SVG (issue #18). The generated PNGs are committed, so this is a
# manual step, not a build dependency — a clean `git diff` after running it
# confirms the checked-in icons are current. See Resources/Icon/README.md.
icons:
	swift Resources/Icon/make-icon.swift

# Build + sign the app (both .appex embedded) and install it to an Applications
# folder (defaults to ~/Applications) so macOS discovers the File Provider
# extension. Signing must be real here — the
# shared keychain group and the testing-mode entitlement need a valid signature —
# so this never passes CODE_SIGNING_ALLOWED=NO.
install:
	xcodegen generate
	xcodebuild -project OwnCloudFileProvider.xcodeproj -scheme App \
		-configuration Debug -destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) -allowProvisioningUpdates build
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALLED_APP)"
	cp -R "$(BUILT_APP)" "$(INSTALLED_APP)"
	codesign --verify --deep --strict "$(INSTALLED_APP)"
	@echo "Installed $(INSTALLED_APP); embedded extensions:"
	@ls "$(INSTALLED_APP)/Contents/PlugIns"

# --- Release (tag-triggered; see PROJECT.md "Releasing") ---------------------
# The same scripts .github/workflows/release.yml runs, so a release is reproducible
# on a developer Mac (AC-4). BUILD defaults to 1 for local trial runs; CI passes the
# workflow run number so CFBundleVersion always increases.
BUILD ?= 1

# Self-test the tag -> version parser. Cheap, and it runs before any archive so a bad
# tag fails in seconds.
release-version-test:
	./scripts/release-version.sh --self-test

# Build the signed .dmg. VERSION must be numeric (1.2.0) — the parser strips the tag's
# `v` and any prerelease suffix, which Apple rejects in CFBundleShortVersionString.
dmg:
	VERSION="$(VERSION)" BUILD="$(BUILD)" ./scripts/make-dmg.sh

# Notarize + staple the app and the image built by `make dmg`. Needs an App Store
# Connect API key (ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID). No VERSION needed —
# the artifact's path comes from dist/artifact-path.txt, written by `make dmg`.
notarize:
	./scripts/notarize.sh
