.PHONY: check syntax lint test

SHELL_FILES := box guest/hb guest/hb-workload guest/profile.sh guest/agent-bash-profile.sh provision/provision.sh tests/static.sh tests/lifecycle-smoke.sh tests/fixtures/smolvm

syntax:
	bash -n $(SHELL_FILES)

lint:
	command -v shellcheck >/dev/null || { echo "shellcheck is required for make check" >&2; exit 1; }
	shellcheck -x -s bash $(SHELL_FILES)

test:
	./tests/static.sh
	./tests/lifecycle-smoke.sh

check: syntax lint test
