# Contributing

## Prerequisites

- Go 1.26.7 or newer, matching the `go` line in `go.mod`
- GNU Make
- Bash, Python 3 with PyYAML, jq, gzip, and tar (the shell regression suite)
- ShellCheck 0.11.0 (`make lint` and `make check`)
- A Docker daemon only when you run a box, or the optional integration tests below

Builds pass `-buildvcs=false`. A shallow checkout or a linked git worktree can
make Go's VCS stamping fail, and the CLI version is set with `-ldflags`.

## Build

```bash
make tx9
```

That writes `bin/tx9` (gitignored). The same build by hand:

```bash
go build -buildvcs=false -ldflags "-X github.com/davis7dotsh/tx9/internal/version.Version=dev" -o bin/tx9 .
```

`go install github.com/davis7dotsh/tx9@latest` installs a published module
version. A source build reports version `dev` and tags its image `tx9-box:dev`.

The binary embeds `box.env`, `provision/`, `guest/`, and `docker/` at compile
time. Rebuild after editing those files before the next `tx9 create` or
`tx9 upgrade`.

Cross-compile the four release binaries and `checksums.txt` into `dist/`:

```bash
make dist VERSION=0.12.1
```

## Test

`make check` is the full local gate: shell syntax, ShellCheck, guest
regressions, a gofmt check, `go vet`, and `go test ./...`.

```bash
make check
make go-check    # gofmt, go vet, go test only
make format      # gofmt -w .
```

GitHub Actions (`.github/workflows/ci.yml`) runs the same gofmt check,
`go vet -buildvcs=false ./...`, `go build -buildvcs=false`, and
`go test -buildvcs=false ./...` on pull requests and on pushes to `main`.

`.depot/workflows/check.yml` runs `make check` and the `site/` Worker checks
on Depot. Changes under `guest/`, `provision/`, `docker/`, `scripts/`, or
`tests/` still need `make check` locally.

### Docker integration tests

`TestEphemeralDockerIntegration` and `TestExecDockerIntegration` talk to a
live daemon. `go test` skips them unless `TX9_TEST_DOCKER_IMAGE` is an image
already present locally that provides `/bin/sh`, `cat`, `ls`, and `sleep`.
The tests create disposable containers and do not mount host data. CI leaves
the variable unset.

```bash
TX9_TEST_DOCKER_IMAGE=ubuntu:24.04 go test -buildvcs=false ./internal/docker/
```

`make go-check` and `make check` pick up the same variable when it is set in
the environment.

## Makefile targets

| Target | What it runs |
| --- | --- |
| `syntax` | `bash -n` / `sh -n`, and a Python compile of the guest and release scripts |
| `lint` | ShellCheck on the bash scripts, and on `scripts/install.sh` as POSIX sh |
| `test` | `tests/static.sh`, `tests/hermes-state.sh`, and `tests/regressions-*.sh` |
| `go-check` | gofmt check, `go vet ./...`, `go test ./...` |
| `check` | `syntax`, `lint`, `test`, and `go-check` |
| `format` | `gofmt -w .` |
| `tx9` | Build `bin/tx9` |
| `dist` | Cross-compile release binaries into `dist/` (`VERSION=` stamps the binary) |

`make test` is the shell suite. The Go tests are `make go-check`.
