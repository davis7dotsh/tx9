# tx9

Isolated, portable agent boxes with **Claude Code, Codex, Hermes, and
Executor**, running on Docker. Each box is a pair of containers on a private
network — a free-rein agent container and an isolated Executor container —
with portable agent state on a named volume that travels as an encrypted,
validated backup archive. Executor scratch state and runtime logs remain on a
separate durable-but-non-portable volume.

**Status: experiment, mid-transition.** The bash prototypes (smolvm `./box`
and the compose `./docker/boxd`) have been retired in favor of a Go CLI
(`tx9`, this repo, embedding its provisioning and guest assets) that is now
implemented, released, and under active development, though still experimental.
See [docs/tx9-cli-design.md](docs/tx9-cli-design.md) for the full
design and [docs/docker-architecture.md](docs/docker-architecture.md) for
the runtime architecture and its verification history.

For a stable HTTPS Executor origin and OAuth callbacks over a tailnet, see
[Tailscale HTTPS for Executor](docs/tailscale-executor.md).
For host directories and NAS shares that should be visible inside an agent,
see [Host mounts](docs/host-mounts.md).

## Model

```text
tx9 create                      (Go CLI, embedded build assets)
      ▼
 compose-style project per box ─────────────────────────────────┐
 │  ┌───────────────────────┐      ┌─────────────────────────┐  │
 │  │ agent ("linux land")  │      │ executor                │  │
 │  │ claude·codex·hermes   │      │ Executor daemon only    │  │
 │  │ gateway, sudo, free   │      │ dashboard / + MCP /mcp  │  │
 │  │ agent volume = the box│      │ scratch + runtime logs  │  │
 │  │ no published ports    │      │ one configurable port   │  │
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

Run `tx9` with no arguments for an ASCII overview of every configured box,
including status, CPU/RAM limits, volume usage/budgets, image version, and
dashboard URL. The compact `tx9 list` table remains available for scripts.

External host storage can be attached below `/mnt` without folding it into the
portable box volume:

```bash
tx9 mount add media-bot "$HOME/agents" /mnt/agents --require-mountpoint
tx9 mount list media-bot
```

Mount configuration survives container recreation and box upgrades. The host
is still responsible for mounting and authenticating the underlying share.

## Repository layout

| Path | Role |
|---|---|
| `box.env` | Build/runtime configuration: tool versions/channels and feature flags |
| `site/` | Cloudflare Worker for tx9.col-agents.com: homepage, `/install` script, release downloads from R2 |
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
hb logs hermes
```

The host CLI exposes the safe gateway lifecycle directly:

```bash
tx9 gateway status <box>
tx9 gateway enable <box> --confirm-single-writer
tx9 gateway disable <box>
```

## Logs and resource allocation

Runtime output from the agent supervisor, Hermes gateway, and Executor is
written to the component's own durable volume as rotating structured JSONL
and readable text logs. Codex and Claude Code already keep native JSONL
session histories on the agent volume; Hermes keeps its canonical SQLite
history there. Query all of them from the host without weakening the
agent/Executor filesystem boundary:

```bash
tx9 logs media-bot --source executor,codex --since 24h --grep failed
tx9 logs media-bot --json | jq .
tx9 logs export media-bot --output media-bot-logs.tar.gz
```

Known bearer-token forms are redacted by default. Log exports are created
mode `0600`; they can still contain prompts, tool output, and private work, so
treat them as sensitive. Existing boxes begin collecting the new durable
runtime streams after `tx9 upgrade <box>`.

TX9 captures all runtime output produced by the processes it owns and queries
the native histories those agents persist. This is not an independent audit
log for Executor calls that Executor itself never emits; operations initiated
by an external dashboard/client may only be visible when upstream writes a
corresponding runtime event.

Container CPU and memory limits can be inspected, changed live, reset to the
current defaults, and retained across upgrades or mount-driven recreation:

```bash
tx9 resources media-bot
tx9 resources set media-bot --agent-cpus 6 --agent-memory 12GiB \
  --executor-cpus 3 --executor-memory 4GiB \
  --agent-volume-budget 96GiB
tx9 resources reset media-bot
```

Docker's ordinary local named volumes have no portable, resizable hard quota.
TX9 therefore reports their real used bytes and `unlimited` capacity by
default; optional volume values are explicitly advisory budgets used for
visibility and over-budget warnings, not filesystem enforcement.

If a container was configured outside tx9 with unlimited CPU or RAM, use
`tx9 upgrade <box>` plus the desired resource flags to move it to a finite
limit. Docker's live update API cannot safely roll that transition back.

Fresh and restored boxes begin with the Hermes gateway durably disabled so
setup and migration cannot create a second Discord writer; enabling it is
always an explicit, confirmed step. Do not use `hermes gateway run` as the
persistent TX9 lifecycle: it is foreground work and exits with its terminal.
Executor runs remotely from the agent's perspective (`EXECUTOR_HOST=executor`):
`hb` checks reachability and wires MCP with the injected bearer token; it never
spawns or stops the daemon.

## Backup guarantees

Saves quiesce the gateway, checkpoint SQLite, archive agent `/data` (minus
caches, PIDs, locks, and DB sidecars), validate the archive member-by-member
(absolute paths, traversal, special files, duplicate members, unsafe
symlink/hardlink targets, link cycles), encrypt with GPG AES-256, then
decrypt-verify before publishing without overwriting. Restores validate
before creating anything, stage-then-promote inside a throwaway container,
re-arm the quiesce and gateway-disable markers, mint a fresh executor token,
and rewire MCP automatically.

Agent-side logs and native histories travel with a normal `.tx9` backup.
Executor runtime logs remain on its deliberately non-portable scratch volume;
use `tx9 logs export` when those should travel too.

## Local validation

```bash
make check          # syntax + shellcheck + static contracts + regressions; hermetic
```

`.depot/workflows/check.yml` runs `make check` on every push and pull request
to `main` via Depot CI.
