.PHONY: check syntax lint test

SHELL_FILES := box guest/hb guest/hb-workload guest/profile.sh guest/agent-bash-profile.sh provision/provision.sh ops/tx9-host tests/static.sh tests/lifecycle-smoke.sh tests/hermes-state.sh tests/regressions.sh tests/fixtures/smolvm

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

check: syntax lint test
