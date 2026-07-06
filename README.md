# tx9

Isolated, portable agent boxes with **Claude Code, Codex, Hermes, and
Executor**, running on Docker. Each box is a pair of containers on a private
network — a free-rein agent container and an isolated Executor container —
with all durable state on a named volume that travels as an encrypted,
validated backup archive.

**Status: experiment, mid-transition.** The bash prototypes (smolvm `./box`
and the compose `./docker/boxd`) have been retired in favor of a Go CLI
(`tx9`, this repo, embedding its provisioning and guest assets) that is now
implemented and under active development — still experimental, not yet
released. See [docs/tx9-cli-design.md](docs/tx9-cli-design.md) for the full
design and [docs/docker-architecture.md](docs/docker-architecture.md) for
the runtime architecture and its verification history.

## Model

```text
tx9 create                      (Go CLI, embedded build assets)
      ▼
 compose-style project per box ─────────────────────────────────┐
 │  ┌───────────────────────┐      ┌─────────────────────────┐  │
 │  │ agent ("linux land")  │      │ executor                │  │
 │  │ claude·codex·hermes   │      │ Executor daemon only    │  │
 │  │ gateway, sudo, free   │      │ dashboard / + MCP /mcp  │  │
 │  │ agent volume = the box│      │ scratch volume          │  │
 │  │ no published ports    │      │ one 0.0.0.0 host port   │  │
 │  └───────────┬───────────┘      └───┬─────────────────────┘  │
 │              │ http://executor:4788 │ bearer-token gated     │
 │              └── private network ───┘                        │
 └──────────────────────────────────────────────────────────────┘
      ▼
 <box>-<timestamp>.tx9          encrypted, validated state archive
```

The agent volume is the box; containers are disposable; tools are image
layers ("upgrade" = rebuild image + recreate containers). Executor state is
scratch and does not travel. Networking is always enabled because the agent
tools require internet access.

## Repository layout

| Path | Role |
|---|---|
| `box.env` | Build/runtime configuration: tool pins, Hermes installer SHA pin, feature flags |
| `site/` | Cloudflare Worker for tx9.davis7.sh: homepage, `/install` script, release downloads from R2 |
| `provision/provision.sh` | Runs inside `docker build` (`tools` + `assets` layers); installs everything |
| `guest/` | In-box runtime: `hb` control CLI, `hb-workload` reconcile loop, `hermes-state` validator, profiles, tmux config |
| `docker/` | Image build assets: `Dockerfile`, agent + executor entrypoints |
| `docs/` | Architecture, CLI design, operations history |
| `tests/` | Static contract checks and guest-script regressions (`make check`) |

## In-box control (`hb`)

Inside the agent container:

```bash
hb status / hb doctor / hb versions
hb down            # durable pause; the reconcile loop won't restart services
hb up
hb gateway-enable --confirm-single-writer I_CONFIRM_NO_OTHER_GATEWAY_USES_THIS_IDENTITY
hb gateway-disable
hb verify-state
hb wire-mcp        # (re)register Executor's authenticated HTTP MCP for claude+codex
hb logs executor
```

Fresh and restored boxes begin with the Hermes gateway durably disabled so
setup and migration cannot create a second Discord writer; enabling it is
always an explicit, confirmed step. Executor runs remotely from the agent's
perspective (`EXECUTOR_HOST=executor`): `hb` checks reachability and wires
MCP with the injected bearer token; it never spawns or stops the daemon.

## Backup guarantees

Saves quiesce the gateway, checkpoint SQLite, archive agent `/data` (minus
caches, PIDs, locks, and DB sidecars), validate the archive member-by-member
(absolute paths, traversal, special files, duplicate members, unsafe
symlink/hardlink targets, link cycles), encrypt with GPG AES-256, then
decrypt-verify before publishing without overwriting. Restores validate
before creating anything, stage-then-promote inside a throwaway container,
re-arm the quiesce and gateway-disable markers, mint a fresh executor token,
and rewire MCP automatically.

## Local validation

```bash
make check          # syntax + shellcheck + static contracts + regressions; hermetic
make check-hermes-pin   # network: compare HERMES_INSTALLER_SHA256 against upstream
```

`.depot/workflows/check.yml` runs `make check` on every push and pull request
to `main` via Depot CI.

If an image build fails with "Hermes installer checksum verification failed",
upstream rotated `install.sh` since the pin: run `make check-hermes-pin`,
review the new installer, then update `box.env` yourself.
