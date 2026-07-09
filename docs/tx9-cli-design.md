# tx9 CLI — design

Status: agreed 2026-07-04 (12 decisions below, settled in conversation with
Davis). Nothing here is implemented yet; this document is the spec the Go
implementation is built from. The bash prototypes that informed it (`./box`
on smolvm, `./docker/boxd` on compose) are deleted; recover them from git
history (`9350212` and earlier) when porting logic.

## What tx9 is

A single Go binary installed on a machine ("tx9") that creates and manages
hermes boxes — the two-container agent/executor pairs described in
[docker-architecture.md](docker-architecture.md). No repo checkout, no
`./docker/boxd`, no compose plugin. The CLI is the product; the repo is its
source.

```
curl -fsSL https://tx9.col-agents.com/install | bash
tx9 create
```

## The 12 decisions

| # | Question | Decision |
|---|---|---|
| 1 | Image source | **Embedded assets, local build.** The binary `go:embed`s provision/, guest/, Dockerfile, box.env; first `create` builds the image locally (~10 min, then cached). No registry. |
| 2 | State home | **`~/.tx9/`** — `boxes/<name>.env` (token cache), `locks/`, `config.toml`. Docker objects are label-tagged so `tx9 list` reconstructs truth from the daemon even if `~/.tx9` is lost. Backups default to **`~/Downloads`**. |
| 3 | Naming + create UX | Friendly generated names (`large-cat` style) by default, `tx9 create my_box` for explicit. `create` ends with a printed numbered checklist (enter, auth claude/codex, hermes setup, dashboard URL). |
| 4 | Command surface | See table below. `enter`/`ssh` are aliases; `backup`/`export` are aliases. |
| 5 | Password UX | Precedence: `--password` flag → `TX9_PASSWORD` env → interactive hidden prompt. **`--no-encrypt` escape hatch** for quick local snapshots. |
| 6 | Archive format | **`.tx9` extension** (tar.gz inside, GPG-wrapped unless --no-encrypt; CLI sniffs which). Embeds box-name metadata; `import` restores under that name, `--name` overrides, collision = hard fail. |
| 7 | Scope | **Local-only v1.** The CLI drives the local Docker daemon; cross-machine moves are backup → transfer yourself → import. (Remote is a saved future direction — see below.) |
| 8 | Docker interface | **Engine API via the official Go SDK**, not shelling to compose. tx9 creates the network/volumes/containers itself. Kills the compose-plugin dependency (bit us on siva) and owns all progress/error UX. |
| 9 | Repo | **This repo.** Go code lives alongside provision/ and guest/ because they co-evolve; embedding pulls from source at build time. |
| 10 | Distribution | **GitHub Releases** (cross-compiled, tag-push CI) for `tx9 upgrade` self-update, mirrored to an **R2 bucket behind `https://tx9.col-agents.com`** (`site/`, a Cloudflare Worker: homepage + `/install` + `/releases/*`) for `curl \| sh` installs — works while the repo is still private. Installer detects OS/arch, drops binary in `~/.local/bin`. |
| 11 | Versioning | `tx9 upgrade` (no args) self-updates the CLI; `tx9 upgrade <box>` moves a box onto the current image. Images tagged `tx9-box:<cli-version>`; `list` shows per-box image version so drift is visible; unused old images pruned. |
| 12 | Bash prototypes | **Both deleted** (done, this commit). git history is the reference. |

## Command surface

| Command | Behavior |
|---|---|
| `tx9 create [name]` | Generate name if absent. Build `tx9-box:<version>` if missing (with real progress UX). Create network + volumes + both containers, mint token, wire MCP, run doctor. Print getting-started checklist. |
| `tx9 list` | All boxes on this machine from daemon labels: state (running/stopped/crashed), image version vs CLI version (drift flag), dashboard URL. |
| `tx9 enter <box>` (alias `ssh`) | Exec into the agent container as `agent`, tmux `main` attach. Starts the box if stopped. |
| `tx9 start <box>` / `tx9 stop <box>` | Both containers together. Volumes persist. |
| `tx9 backup <box>` (alias `export`) | Flags: `--path` (default `~/Downloads`), `--password`/env/prompt, `--no-encrypt`. Quiesce → archive agent /data → validate → (encrypt) → verify → `<box>-<timestamp>.tx9`. |
| `tx9 import <file.tx9>` | Flags: `--name`, `--password`/env/prompt. Validate before creating anything; restore staged; arrive quiesced + gateway-disabled + fresh token; fail on name collision. |
| `tx9 gateway <status\|enable\|disable> <box>` | Inspect or control the container-supervised Hermes gateway. Enable requires `--confirm-single-writer`. |
| `tx9 open <box>` | Print (or open) the authenticated dashboard URL (`?_token=`). |
| `tx9 doctor <box>` | In-box `hb doctor` + host-side published-port probe. |
| `tx9 upgrade [box]` | No args: self-update (re-run installer logic). With box: recreate containers on current image + readiness gate. |
| `tx9 delete <box>` | Containers + volumes + token file, typed-name confirmation (`--force` to skip). |
| `tx9 prune` | Remove unused `tx9-box:*` image versions and stale state files. |

`create`, `import`, and box-specific `upgrade` accept the shared
`--executor-web-base-url`, `--executor-publish`, and `--executor-dns` options.
Their resolved values are persisted per box and reused on future upgrades.
`--clear-executor-config` returns a box to the default dynamic HTTP exposure.

## Fixed contracts (carried from the verified bash draft)

These were dry-run- and QA-verified in the boxd prototype and must survive
the port:

- **Topology**: agent container (no published ports, volume = the box, sudo,
  IPv6 disabled via sysctl) + executor container (daemon only,
  `--hostname 0.0.0.0 --port 4788 --auth-token <token>`, one published
  host port (all interfaces/automatic by default, optionally fixed and
  loopback-only), scratch volume) + per-box private network. Labels
  (`tx9=1`, `tx9.box=<name>`, `tx9.version=<v>`) on every object.
- **Token**: 256-bit random per box, minted at create/import, injected as
  `BOXD_EXECUTOR_TOKEN` (outranks any restored on-disk `executor-mcp.env` —
  real bug found in dry run) and `EXECUTOR_HOST=executor`. `hb wire-once`
  re-wires when token *or URL* is stale.
- **Archive safety**: the member-by-member validator (absolute paths,
  traversal, special files, duplicates, link targets/cycles/nesting) ported
  from bash+python to Go. Validate before create on import; validate after
  tar on backup. Restores stage-then-promote in a throwaway container and
  re-arm quiesce + gateway-disabled markers.
- **Gateway single-writer**: restored boxes never auto-enable the Hermes
  gateway. `tx9 gateway enable <box> --confirm-single-writer` delegates to
  `hb gateway-enable` and stays the only host-side path.
- **Executor public origin**: create/import/upgrade optionally persist an exact
  `EXECUTOR_WEB_BASE_URL`, fixed host publish address, and container DNS list.
  This supports HTTPS reverse proxies such as Tailscale Serve without losing
  the callback origin or proxy target on the next container recreation.
- **Entrypoints**: agent PID-1 = `hb init` (fail fast) + hb-workload loop
  under docker `--init`; executor PID-1 = foreground daemon. Restart policy
  `unless-stopped`.
- **Gotchas to preserve**: containers need
  `net.ipv6.conf.all.disable_ipv6=1` (executor binds `localhost` → `::1`
  otherwise); right after start the executor needs a boot-window retry
  before health checks pass.

## Go implementation notes

- `go:embed` a tar of `provision/`, `guest/`, `docker/Dockerfile`,
  entrypoints, `box.env` → feed to the Engine API's ImageBuild as the build
  context. Image tag from the CLI's ldflags version.
- Name generator: small embedded adjective+animal word lists.
- Per-box flock in `~/.tx9/locks/` (same semantics as boxd: one operation
  per box; fail fast, don't queue).
- `create` progress: stream ImageBuild output through a spinner/step UI on
  first build; subsequent creates are seconds.
- `.tx9` format: tar.gz of `/data` plus a small JSON metadata header
  (box name, created-at, CLI/image version, encrypted flag). Simplest
  encoding: outer tar with `metadata.json` + `data.tar.gz[.gpg]` members —
  sniffable, streamable, and the metadata stays readable without the
  passphrase.
- Encryption: keep GPG-compatible AES-256 symmetric (shell out to gpg, or
  use a Go OpenPGP lib) so operators can decrypt archives without tx9 in an
  emergency.
- Doctor/MCP checks: port `lib-mcp.sh`'s initialize handshake to Go (proper
  HTTP client, jq logic in code).

## Saved for later (explicitly out of v1)

- **Remote/multi-host** — worth doing eventually: `tx9 --host nexus list`,
  or `tx9 move large-cat nexus` (backup → stream → import → gateway gates,
  one command from a laptop). Design constraint to keep in mind now: keep
  the daemon interface behind a small interface type so a remote Docker
  daemon (SSH tunnel / `DOCKER_HOST`) slots in without restructuring.
- Hosted docs/site at tx9.col-agents.com beyond the install redirect.
- Registry-published images (decision 1 fallback if local builds annoy).
- Compose healthchecks / `depends_on: service_healthy` equivalents via the
  SDK health config.
- Executor-state backup (currently: scratch by contract, does not travel).
- Slim executor image variant; token rotation command; executor egress
  policy network.

## Migration to tx9

The guest layer (`guest/`, `provision/`, `box.env`) is shared and already
compose-split aware, so existing boxd-created boxes are structurally
identical to what tx9 will create — only labels/names differ
(`hbl-*` vs `tx9-*`). Don't build compatibility: the running dry boxes are
disposable, and any box that matters moves via `backup`/`import` anyway.
