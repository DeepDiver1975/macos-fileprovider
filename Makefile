# Single local entry point for the acceptance / backend-contract tiers (AC-4):
# the same fixtures and tests CI runs, no CI-only wiring.
#
#   make backend-contract BACKEND=classic   # bring up Classic, run the tier, tear down
#   make backend-contract BACKEND=ocis       # same for oCIS
#   make unit                                # the pure-unit swift test run
#   make up   BACKEND=classic|ocis           # just start a fixture
#   make down BACKEND=classic|ocis           # just stop it
#   make install                             # build + sign the app, install to ~/Applications
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

.PHONY: unit backend-contract up down wait clean install

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
