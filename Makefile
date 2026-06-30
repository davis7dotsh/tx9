.PHONY: check syntax lint test check-hermes-pin

SHELL_FILES := box guest/hb guest/hb-workload guest/profile.sh guest/agent-bash-profile.sh provision/provision.sh ops/tx9-host tests/static.sh tests/lifecycle-smoke.sh tests/hermes-state.sh tests/regressions.sh tests/cli-surface.sh tests/fixtures/smolvm

syntax:
	bash -n $(SHELL_FILES)
	python3 -c 'compile(open("guest/hermes-state", encoding="utf-8").read(), "guest/hermes-state", "exec")'

lint:
	command -v shellcheck >/dev/null || { echo "shellcheck is required for make check" >&2; exit 1; }
	shellcheck -x -s bash $(SHELL_FILES)

test:
	command -v python3 >/dev/null || { echo "python3 is required for local regression tests" >&2; exit 1; }
	command -v jq >/dev/null || { echo "jq is required for local regression tests" >&2; exit 1; }
	./tests/static.sh
	./tests/lifecycle-smoke.sh
	./tests/hermes-state.sh
	./tests/regressions.sh
	./tests/cli-surface.sh

check: syntax lint test

# Not part of `check` — needs network access, so `make check` stays hermetic.
# Run this on its own to catch Hermes installer drift before it surfaces as a
# `box new` failure for a real user.
check-hermes-pin:
	@command -v curl >/dev/null || { echo "curl is required for check-hermes-pin" >&2; exit 1; }
	@pinned=$$(grep '^HERMES_INSTALLER_SHA256=' box.env | sed -E 's/^[A-Z0-9_]+="([^"]*)"/\1/'); \
	live=$$(curl -fsSL https://hermes-agent.nousresearch.com/install.sh | sha256sum | awk '{print $$1}'); \
	if [ -z "$$live" ]; then echo "failed to fetch live Hermes installer" >&2; exit 1; fi; \
	if [ "$$pinned" = "$$live" ]; then \
		echo "HERMES_INSTALLER_SHA256 matches upstream ($$live)"; \
	else \
		echo "HERMES_INSTALLER_SHA256 in box.env ($$pinned) does NOT match upstream ($$live)" >&2; \
		echo "review the new installer before re-pinning, then update box.env" >&2; \
		exit 1; \
	fi
