.PHONY: check syntax lint test check-hermes-pin tx9 go-check dist

# tests/regressions-*.sh is globbed so new split-out regression files don't
# require touching this Makefile.
SHELL_FILES := guest/hb guest/hb-workload guest/lib-mcp.sh guest/profile.sh guest/agent-bash-profile.sh provision/provision.sh docker/entrypoint.sh docker/executor-entrypoint.sh tests/lib.sh tests/static.sh tests/hermes-state.sh $(wildcard tests/regressions-*.sh)

syntax:
	bash -n $(SHELL_FILES)
	sh -n scripts/install.sh
	python3 -c 'compile(open("guest/hermes-state", encoding="utf-8").read(), "guest/hermes-state", "exec")'

lint:
	command -v shellcheck >/dev/null || { echo "shellcheck is required for make check" >&2; exit 1; }
	shellcheck -x -s bash $(SHELL_FILES)
	# scripts/install.sh is a #!/bin/sh installer (must run under plain
	# POSIX sh via `curl | sh`), so it's linted against the sh dialect
	# separately rather than folded into SHELL_FILES/-s bash above.
	shellcheck -x -s sh scripts/install.sh

test:
	command -v python3 >/dev/null || { echo "python3 is required for local regression tests" >&2; exit 1; }
	command -v jq >/dev/null || { echo "jq is required for local regression tests" >&2; exit 1; }
	./tests/static.sh
	./tests/hermes-state.sh
	for f in tests/regressions-*.sh; do ./"$$f" || exit 1; done

check: syntax lint test go-check

# Not part of `check` — needs network access, so `make check` stays hermetic.
# Run this on its own to catch Hermes installer drift before it surfaces as a
# `box new` failure for a real user.
check-hermes-pin:
	@command -v curl >/dev/null || { echo "curl is required for check-hermes-pin" >&2; exit 1; }
	@if command -v sha256sum >/dev/null; then hasher="sha256sum"; \
	elif command -v shasum >/dev/null; then hasher="shasum -a 256"; \
	else echo "sha256sum or shasum (macOS) is required for check-hermes-pin" >&2; exit 1; fi; \
	pinned=$$(grep '^HERMES_INSTALLER_SHA256=' box.env | sed -E 's/^[A-Z0-9_]+="([^"]*)"/\1/'); \
	tmp=$$(mktemp); \
	trap 'rm -f "$$tmp"' EXIT; \
	if ! curl -fsSL --connect-timeout 10 --max-time 30 https://hermes-agent.nousresearch.com/install.sh -o "$$tmp"; then \
		echo "failed to fetch live Hermes installer" >&2; exit 1; \
	fi; \
	live=$$($$hasher "$$tmp" | awk '{print $$1}'); \
	if [ "$$pinned" = "$$live" ]; then \
		echo "HERMES_INSTALLER_SHA256 matches upstream ($$live)"; \
	else \
		echo "HERMES_INSTALLER_SHA256 in box.env ($$pinned) does NOT match upstream ($$live)" >&2; \
		echo "review the new installer before re-pinning, then update box.env" >&2; \
		exit 1; \
	fi

VERSION ?= dev

# -buildvcs=false: this worktree's .git is a linked-worktree gitlink file, not
# a directory, and `go build`'s VCS-root walk doesn't recognize it — it walks
# past the real repo and can land on an unrelated .git elsewhere up the tree,
# failing with "error obtaining VCS status: exit status 128". The CLI's
# version comes from -ldflags, not VCS stamping, so this is a no-op for us.
tx9:
	go build -buildvcs=false -ldflags "-X github.com/davis7dotsh/tx9/internal/version.Version=$(VERSION)" -o bin/tx9 .

go-check:
	@test -z "$$(gofmt -l .)" || { echo "gofmt: unformatted files:" >&2; gofmt -l . >&2; exit 1; }
	go vet -buildvcs=false ./...
	go build -buildvcs=false ./...
	go test -buildvcs=false ./...

# Cross-compiles the release binaries + checksums.txt into dist/. Asset
# naming here MUST match internal/selfupdate.AssetName and
# .depot/workflows/release.yml: plain, uncompressed executables named
# tx9_<GOOS>_<GOARCH>, plus a checksums.txt in `sha256sum` output format.
DIST_PLATFORMS := linux/amd64 linux/arm64 darwin/amd64 darwin/arm64

dist:
	rm -rf dist
	mkdir -p dist
	for platform in $(DIST_PLATFORMS); do \
		goos=$${platform%/*}; goarch=$${platform#*/}; \
		out="dist/tx9_$${goos}_$${goarch}"; \
		echo "building $$out"; \
		GOOS=$$goos GOARCH=$$goarch go build -buildvcs=false -ldflags "-X github.com/davis7dotsh/tx9/internal/version.Version=$(VERSION)" -o "$$out" . || exit 1; \
	done
	cd dist && { command -v sha256sum >/dev/null 2>&1 && sha256sum tx9_* > checksums.txt || shasum -a 256 tx9_* > checksums.txt; }
	@echo "dist/ ready (VERSION=$(VERSION))"
