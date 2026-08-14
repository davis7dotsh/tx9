# AGENTS.md

## Cursor Cloud specific instructions

This repo is the `tx9` Go CLI (plus guest shell/python scripts) that builds and
runs Docker-based agent "boxes". Two things you actually run here: the local
dev validation (`make check`) and the CLI/product itself against a Docker
daemon.

### Toolchain / environment

- `go.mod` requires **Go 1.26**, but the base image's system `go` is 1.22 and
  cannot auto-download the 1.26 toolchain in this network. Go 1.26 is installed
  under `/usr/local/go` and prepended to `PATH` in `~/.bashrc`. New login shells
  pick it up automatically; verify with `go version` (expect `go1.26.x`).
- `make check` also needs `shellcheck` (pinned to **v0.11.0**, installed at
  `/usr/local/bin/shellcheck`), plus `jq` and `python3` (already present).
- Go builds use `-buildvcs=false` (see the `Makefile`): this worktree's `.git`
  is a linked-worktree gitlink file and VCS stamping fails without it.

### Dev validation (hermetic, no Docker needed)

- `make check` runs syntax + shellcheck + static contracts + guest regressions
  + `go vet`/`gofmt`/`go build`/`go test`. This is the full CI gate
  (`.depot/workflows/check.yml`) and is the primary thing to run before
  committing. Build just the CLI with `make tx9` (output: `bin/tx9`, gitignored).

### Running the product (needs Docker)

- Start the daemon yourself: `sudo dockerd` (run it in a long-lived tmux session;
  it is not managed by systemd here). Docker uses the `fuse-overlayfs` storage
  driver and `iptables-legacy` in this VM.
- The invoking user is in the `docker` group, but a shell started before that
  change won't have it; use a fresh login shell or `sg docker -c '<cmd>'` to run
  `tx9` against the daemon.
- Core flow: `tx9 create <name>` (builds the `tx9-box:dev` image via
  `provision/provision.sh`, first build ~10 min), then `tx9 list`, `tx9 doctor`,
  `tx9 enter`, `tx9 open <name>` (authenticated dashboard URL), `tx9 delete`.

### Non-obvious gotchas

- **The CLI embeds the build context at compile time.** `assets.go` `go:embed`s
  `box.env`, `provision/`, `guest/`, and the `docker/` files. Editing `box.env`
  or those assets has **no effect on `tx9 create` until you rebuild the binary**
  (`make tx9`). Don't expect Docker's `COPY box.env` layer to change otherwise.
- **A full box build currently fails on the Hermes `[messaging]` extra.** The
  upstream `hermes-agent` package refuses to be built from source, so
  `provision.sh`'s `uv pip install .[messaging]` step (`install_hermes_messaging_deps`)
  errors out with "Building wheels or sdists for hermes-agent is not supported".
  Everything else (vite+/node, uv, claude-code, codex, executor) provisions
  fine. To build and run a working box for testing, set `INSTALL_HERMES=0` in
  `box.env` and rebuild the binary (`make tx9`) first; the box then comes up with
  the Executor daemon + dashboard and passes `tx9 doctor`. This is a temporary
  test toggle — do not commit it.
