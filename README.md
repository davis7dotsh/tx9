# tx9

Isolated, portable agent boxes with **Claude Code, Codex, Hermes, and
Executor**, running on Docker. Each box is a pair of containers on a private
network — a free-rein agent container and an isolated Executor container —
with portable agent state on a named volume that travels as an encrypted,
validated backup archive. Executor scratch state and runtime logs remain on a
separate durable-but-non-portable volume.

**Security limit:** the agent receives Executor's administrator token.
Separate containers do not keep Executor credentials confidential from that
agent. Read the [security model](docs/security-model.md) before connecting
sensitive accounts or host storage.

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

| Path                     | Role                                                                                                            |
| ------------------------ | --------------------------------------------------------------------------------------------------------------- |
| `box.env`                | Build/runtime configuration: tool versions/channels and feature flags                                           |
| `site/`                  | Cloudflare Worker for tx9.col-agents.com: homepage, `/install` script, release downloads from R2                |
| `provision/provision.sh` | Runs inside `docker build` (`tools` + `assets` layers); installs everything                                     |
| `guest/`                 | In-box runtime: `hb` control CLI, `hb-workload` reconcile loop, `hermes-state` validator, profiles, tmux config |
| `docker/`                | Image build assets: `Dockerfile`, agent + executor entrypoints                                                  |
| `docs/`                  | Architecture, CLI design, operations history                                                                    |
| `tests/`                 | Static contract checks and guest-script regressions (`make check`)                                              |

## In-box control (`hb`)

Inside the agent container:

```bash
hb status / hb doctor / hb versions
hb down            # durable pause; the reconcile loop won't restart services
hb up
hb services        # status for portable custom service drop-ins
hb services-reload # reconcile custom services immediately
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

### Portable custom services

An executable regular file placed directly in
`~/.config/hermes-box/services.d/` defines a custom service. Names must match
`[a-z0-9][a-z0-9_-]{0,62}`; directories, symlinks, non-executable files, and
unsafe names are ignored and reported by `hb services`. Definitions live on
the portable `/data` volume, so they survive backup, import, and upgrade.

Each file is executed directly by absolute path, without shell sourcing,
evaluation, arguments, or interpolation. Scripts must remain in the
foreground and should `exec` their daemon. For example:

```bash
install -d -m 700 ~/.config/hermes-box/services.d
cat >~/.config/hermes-box/services.d/signal <<'EOF'
#!/usr/bin/env bash
exec signal-cli daemon
EOF
chmod 700 ~/.config/hermes-box/services.d/signal
hb services-reload
```

The existing 20-second workload loop also reconciles definitions
automatically. Each service is supervised independently with a bounded
restart delay; one crashing service cannot block the others. `hb pause` and
`hb down` synchronously stop all custom services and prevent restart, while
`hb up`/`hb resume` start them again. Disabling only the Hermes gateway does
not affect custom services. Container termination is forwarded through the
log supervisor to each foreground process.

`hb services` distinguishes a stable foreground child (`running`) from a
live capture wrapper waiting to restart it (`restarting`). This is process
state, not an application health check; `hb doctor` cannot infer a generic
health contract for arbitrary service code.

Service output uses the same rotating, redacted durable log pipeline as other
tx9-owned processes. Sources are distinct and collision-free:

```bash
tx9 logs media-bot --source service-signal
tx9 logs media-bot --source all
```

Drop-ins have the same permissions and network/filesystem access as the
`agent` user. Treat installing one as installing executable code in the box;
the filename and regular non-symlink checks prevent accidental shell
evaluation or symlink execution, but do not sandbox trusted service code.

## Logs and resource allocation

Runtime output from the agent supervisor, Hermes gateway, and Executor is
written to the component's own durable volume as rotating structured JSONL
and readable text logs. Codex and Claude Code already keep native JSONL
session histories on the agent volume; Hermes keeps its canonical SQLite
history there. Query all of them from the host without weakening the
agent/Executor filesystem boundary:

```bash
tx9 logs media-bot --source executor,codex --since 24h --grep failed
tx9 logs media-bot --level warn --since 24h
tx9 logs media-bot --json | jq .
tx9 logs export media-bot --level warn --output media-bot-logs.tar.gz
```

Events carry a best-effort `level` (debug/info/warn/error) parsed from known
log formats; `--level` keeps that level and above, counting unleveled events
as info. The same threshold filters an export's `events.jsonl` and is recorded
as `manifest.filters.level`. Steady-state noise is kept out of the durable
streams: the reconcile loop logs Executor reachability only when it changes,
and capture collapses consecutive identical lines into one event plus a
repeat-count summary while raw text logs stay byte-faithful. Multi-line Hermes
records (tracebacks, embedded files) are grouped into single events.

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
