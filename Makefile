# Single local entry point for the acceptance / backend-contract tiers (AC-4):
# the same fixtures and tests CI runs, no CI-only wiring.
#
#   make backend-contract BACKEND=classic   # bring up Classic, run the tier, tear down
#   make backend-contract BACKEND=ocis       # same for oCIS
#   make unit                                # the pure-unit swift test run
#   make up   BACKEND=classic|ocis           # just start a fixture
#   make down BACKEND=classic|ocis           # just stop it
#
# BACKEND selects the fixture; it defaults to classic.

BACKEND ?= classic
COMPOSE  = docker compose -f test/fixtures/$(BACKEND)/docker-compose.yml

.PHONY: unit backend-contract up down wait clean

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
