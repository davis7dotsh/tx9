# Contributing

## Prerequisites

- Go matching `go.mod` (currently Go 1.26) — verify with `go version`
- Bash, Make, Python 3 (with PyYAML), `jq`, `gzip`, `tar`
- ShellCheck v0.11.0 for `make check`
- Docker, only for running boxes or the opt-in Docker integration tests
- Node 22.18+ with npm, only for the `site/` Worker checks

## Build

```bash
make tx9        # build ./bin/tx9 (VERSION=0.12.0 make tx9 to stamp a version)
make dist       # cross-compile release binaries + checksums.txt into dist/
go run .        # run without building; reports version "dev"
```

The CLI embeds its build context (`box.env`, `provision/`, `guest/`, `docker/`) at compile time, so rebuild after editing those files before testing `tx9 create`.

## Test

```bash
make check      # full gate: syntax, ShellCheck, guest regressions, gofmt, go vet, go test ./...
make format     # gofmt -w .
go test -buildvcs=false ./...          # Go tests only
go test -buildvcs=false -race ./...    # with the race detector
```

GitHub Actions (`.github/workflows/check.yml`) runs the gofmt check, `go vet ./...`, `go build ./...`, and `go test ./...` on pushes to `main` and every pull request. Depot CI (`.depot/workflows/check.yml`) additionally runs the full `make check` and the site checks, and remains the release gate.

### Docker integration tests

Go tests that need a real Docker daemon self-skip unless `TX9_TEST_DOCKER_IMAGE` names an already-installed image with `/bin/sh`, `cat`, `ls`, and `sleep`. They create only disposable containers and never mount host data:

```bash
docker pull ubuntu:24.04
TX9_TEST_DOCKER_IMAGE=ubuntu:24.04 go test -buildvcs=false ./internal/docker/
```

Running boxes end to end (`tx9 create`, `tx9 enter`, `tx9 doctor`) also needs a running Docker daemon and is not part of CI.

### Site checks

```bash
cd site
npm ci --ignore-scripts
npm run check && npm run format:check && npm run lint && npm test
```

## Makefile targets

| Target         | What it does                                                                      |
| -------------- | --------------------------------------------------------------------------------- |
| `make tx9`     | Build `./bin/tx9` with the `VERSION` ldflag (`dev` by default)                    |
| `make check`   | Full local gate: `syntax` + `lint` + `test` + `go-check`                          |
| `make syntax`  | `bash -n` / `sh -n` / Python compile checks for shell and Python sources          |
| `make lint`    | ShellCheck over guest, provision, docker, and test shell scripts                  |
| `make test`    | Static contract checks and guest-script regressions under `tests/`                |
| `make go-check`| gofmt check, `go vet ./...`, and `go test ./...`                                  |
| `make format`  | Format all Go files with `gofmt -w`                                               |
| `make dist`    | Cross-compile linux/darwin amd64+arm64 binaries and `checksums.txt` into `dist/`  |

## Pull requests

- Keep the diff focused, and run `make check` before opening a PR.
- Note the `make check` result in the PR body, and call out any test you could not run.
