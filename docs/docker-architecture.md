# Proposed architecture: hermes-box-lite on Docker

Status: first draft, 2026-07-03. Companion to the working prototype in
`docker/` (`Dockerfile`, `entrypoint.sh`, `boxd`).

## Why move off smolvm

smolvm gives real VM isolation, but in practice it has been the least
reliable part of the system: bespoke lifecycle semantics, the 4 GiB
pack-export cap that forces overlay-slimming gymnastics, provisioning that
streams a tarball into a live VM on **every** `box new` (minutes, network
required, can fail halfway and needs rollback machinery), and `machine exec`
quirks that shaped a lot of defensive code in `./box`.

Docker trades the VM boundary for a mature, boring runtime:

- **Build once, run many.** Provisioning happens once at `docker build`;
  `boxd new` is a `docker run` and completes in seconds. Failed builds leave
  nothing behind, so `_rollback_created`, keep-on-failure, failed-transcript
  saving, and the create/provision/prepare staging in `cmd_new` all disappear.
- **The daemon is the registry.** Containers and volumes are labelled
  `hermes-box-lite=1`; `docker ps`/`volume ls` replace `.boxes`, and the
  Docker daemon's own serialization replaces `.box-locks`.
- **Ports without bookkeeping.** Each container exposes two fixed internal
  bridge ports; Docker publishes them to free host ports. No `_assign_port`,
  no port registry columns, no collision scanning.

## Model

One box = one Docker Compose project (`hbl-<name>`) with **two containers on
a private network**. This split exists because the main security question is
Executor: the agent (Hermes, claude, codex) should be free to do whatever it
wants in its own container, and Executor — the thing that holds real
credentials and takes real actions — should not share a filesystem, process
table, or user namespace with it.

```text
./docker/boxd build          (once per box.env / pin change)
      │  provision.sh runs INSIDE `docker build` (tools layer + assets layer)
      ▼
  image hermes-box-lite:latest        one image, two entrypoints
      │
./docker/boxd new alpha      (seconds)
      ▼
 compose project hbl-alpha ──────────────────────────────────────────┐
 │                                                                   │
 │  ┌────────────────────────────┐     ┌───────────────────────────┐ │
 │  │ agent  ("linux land")      │     │ executor                  │ │
 │  │ claude · codex · hermes    │     │ Executor daemon ONLY      │ │
 │  │ gateway; free rein, sudo   │     │ (foreground, 0.0.0.0:4788,│ │
 │  │                            │     │  fixed bearer token)      │ │
 │  │ volume: agent-data → /data │     │ volume: exec-data → /data │ │
 │  │ THE box; save/load target  │     │ executor scratch state    │ │
 │  │ NO published ports         │     │ publishes 4788 → host     │ │
 │  └─────────────┬──────────────┘     └─────┬──────────────┬──────┘ │
 │                │  http://executor:4788    │              │        │
 │                └──── private network ─────┘              │        │
 └──────────────────────────── (per-project; no cross-box) ─┼────────┘
                                                            ▼
                             host 0.0.0.0:<auto>  — LAN + Tailscale
                             dashboard at /  ·  MCP at /mcp
                             bearer token gates every request
      │
./docker/boxd save alpha     (archives agent /data only)
      ▼
  backups/alpha-<ts>.tar.gz.gpg   — SAME format as ./box save; archives are
                                    interchangeable between the two runtimes
```

Containers are disposable; the `agent-data` volume is the box. The executor
container's volume is scratch — its identity is the bearer token boxd mints
per box into `.boxd/<name>.env` (mode 0600) and injects into both containers.
`hb` inside the agent wires claude/codex MCP against `http://executor:4788/mcp`
with that token (`EXECUTOR_HOST` + `BOXD_EXECUTOR_TOKEN`); the same token
authenticates you to the dashboard/MCP from the LAN or Tailscale.

What the agent container can do to Executor: exactly what any LAN client can
do — talk HTTP to the token-gated endpoint. Nothing else. Cross-box: each
compose project gets its own network, so `alpha`'s agent cannot even resolve
`beta`'s executor (verified: DNS fails).

### What stays exactly the same

- `provision/provision.sh` — unchanged logic, now two cached build layers
  (`tools` for the multi-minute installs, `assets` for repo-owned guest
  files, so guest-script edits rebuild in seconds).
- `guest/` (hb, hb-workload, hermes-state, profiles, tmux) — hb gained a
  remote-executor mode (`EXECUTOR_HOST` ≠ loopback → check reachability and
  wire MCP remotely instead of spawning/stopping a local daemon); everything
  else unchanged.
- `/data` layout, quiesce/gateway-policy markers, the single-writer gateway
  gates, and the encrypted backup format + `hermes-state verify`.
- `box.env` as the single tuning file (now mostly consumed at build time).

### What is deleted

| smolvm machinery | Docker replacement |
| --- | --- |
| `.boxes` registry + mkdir-lock forest + stale-lock recovery | labels + one flock per box |
| `_assign_port`, port ranges, registry columns | `-p 0.0.0.0::<internal>` auto-assign |
| per-`new` provisioning stream, rollback, keep-on-failure, failed transcripts | `docker build` atomicity |
| overlay 4 GiB cap workarounds (`slim`, ffmpeg preseed rationale) | image layers, no pack-export cap |
| `smolvm machine cp` staging + guest temp tracking | `docker exec` stdout / stdin streaming |
| outer while-true supervisor inside the VM spec | `--restart unless-stopped` + `--init` |

Roughly: `./box` is ~1100 lines; `boxd` is ~300, and most of the deleted 800
lines were compensation for smolvm's sharp edges.

## The trade: isolation

Decision (2026-07-03): VM isolation is a nice-to-have; containers are enough
for now, and the agent keeps passwordless sudo inside its container. The
security question that actually matters is **Executor**, and the compose
split answers it structurally rather than with hardening flags:

- The agent container is deliberately permissive — that's linux land, the
  Hermes agent runs around freely, sudo included. What it can reach is the
  network, its own volume, and one token-gated HTTP endpoint.
- Executor's credentials and execution surface live in a container the agent
  cannot exec into, whose filesystem it cannot see, whose processes it cannot
  signal. Compromising the agent gets you the same position as any
  unauthenticated LAN client: an HTTP endpoint that 401s without the token.
  (The agent does hold a valid token — that's its job — so "agent can call
  Executor tools" is by design; "agent can tamper with Executor itself"
  is what the split removes.)
- Per-project networks mean boxes can't see each other at all.

gVisor (`--runtime=runsc`) remains the one-flag escape hatch if VM-grade
isolation is ever wanted back — the design doesn't change.

Networking stance is unchanged from smolvm (always-on, tools need internet).
The executor's single published port binds 0.0.0.0 (LAN + Tailscale, per
decision); the agent container publishes nothing.

## Lifecycle mapping

| smolvm (`./box`) | Docker (`boxd`) | Notes |
| --- | --- | --- |
| `new` (5–10 min) | `build` once + `new` (seconds) | compose up: agent + executor + network |
| `enter` | `enter` | exec into the **agent** container → same tmux attach |
| `ls` | `ls` | agent state + executor dashboard URL per box |
| `doctor` | `doctor` | in-box `hb doctor` (remote-executor aware) + host dashboard probe |
| `save` / `load` | `save` / `load` | same archive format; archives agent /data only; restored boxes arrive quiesced + gateway-disabled with a **fresh executor token** |
| `repair` | `build` + `compose up` again | volumes untouched; "repair" becomes "replace" |
| `import-hermes` | port later | pure `hermes-state` work; runtime-agnostic |
| `stop`/`start`/`rm` | same | both containers together; `rm` deletes containers **and** volumes after typed confirmation |

The "repair becomes replace" row is the philosophical center: containers are
cattle, volumes are pets. Any doubt about a box's runtime → delete the
container, `boxd new`-style recreate against the same volume. There is no
drift to repair because managed bits are image layers.

## Dry-run results (2026-07-03, on nexus-class hardware, Docker 29)

- `boxd build`: one-time, ~10 min (dominated by the Hermes installer), 5.97 GB
  image. No 4 GiB cap to fight; `slim()` still runs but is now optional.
- `boxd new dry1`: **3.4 seconds** to a fully doctor-green box (vs minutes on
  smolvm), including executor up + MCP wiring + full `hb doctor`.
- `save` → `load` roundtrip: 27 MB encrypted archive; restored box came up
  quiesced with gateway disabled, workspace files intact, `/data` permission
  topology (root 711 / root 711 / agent) preserved, `hb resume` + full doctor
  green afterwards.
- `stop`/`start` and `docker restart` preserve state; the reconcile loop
  revives executor after restart without intervention.
- Codex-driven behavioral QA (8 error-path scenarios: duplicate name, invalid
  name, missing box, missing archive, wrong passphrase, nonexistent rm,
  concurrent saves against the per-box lock): all pass, no orphaned
  containers/volumes after any failure path.
- In-box tool verification: claude 2.1.201, codex 0.142.5, hermes, executor
  1.5.28, node 22, uv, nvim, tmux, passwordless sudo, and the /data-pinned
  CLAUDE_CONFIG_DIR/CODEX_HOME/HERMES_HOME env all check out. One cosmetic
  wart: codex prints "could not create PATH aliases: Operation not permitted"
  because the npm global prefix is a root-owned image layer — harmless
  (aliases already exist from build time), but worth silencing later.
- One real Docker-specific gotcha found and fixed: executor's daemon binds
  `localhost`, which in a default Docker container resolves to `::1` first —
  daemon listened on IPv6 loopback while every health check probed
  `127.0.0.1`. Fixed by running containers with
  `--sysctl net.ipv6.conf.all.disable_ipv6=1` (matches the smolvm guest,
  which had no routable IPv6 either).

### Compose-split verification (same day, after the two-container rework)

- `boxd new` on the compose template: agent + executor + private network up,
  MCP wired against `http://executor:4788/mcp`, full doctor green first try.
- Isolation properties verified live: agent container publishes **zero**
  ports; MCP returns 401 without the bearer token and 200 with it (from the
  host and from inside the agent); dashboard serves on the published port;
  `dry1`'s agent cannot resolve `dry3`'s executor (per-project networks).
- save/load across the split: restored box gets a **fresh token**, and
  `hb wire-once` detects the stale restored wiring (old token + old URL in
  the archive) and rewires — this was a real bug found in the dry run: the
  profile sources the restored `executor-mcp.env`, which clobbered the
  injected token env var. Fixed with a `BOXD_EXECUTOR_TOKEN` override that
  outranks the on-disk file, plus a URL-freshness check in `wire_once`.
- The Dockerfile now provisions in two layers (`tools` then `assets`), so
  guest-script iteration rebuilds the image in seconds instead of ~10 min.

## Draft gaps (known, deliberate for a first pass)

- `boxd doctor` only runs the in-box doctor; host-side MCP/API health probes
  from `./box doctor` aren't ported yet.
- `import-hermes` and `extract` aren't ported (both are runtime-agnostic and
  move over mechanically).
- `boxd save` resumes via a single EXIT-trap slot; the multi-box
  pause-tracking arrays from `./box` aren't needed since one boxd invocation
  touches one box.
- Restored boxes re-run `hb init` via the entrypoint, which is what re-owns
  the skeleton, but a `boxd load` doesn't run the `assets` provisioning
  refresh — with Docker it doesn't need to: managed assets are image layers
  and can't have been clobbered by the archive (the archive only touches
  /data).
- Restored boxes start quiesced with the gateway disabled (correct), but the
  `boxd load` UX for walking the cutover gates is just a printed hint.
- No `boxd repair` — intentionally; see above.

## Suggested migration

1. Land `docker/` alongside the smolvm path (no removals), mark experimental.
2. Run a throwaway box (`boxd new scratch`) for day-to-day agent work for a
   week; the state that matters is exercised by real use.
3. Migrate a real box: `./box save alpha` on smolvm → `boxd load` the same
   archive → walk the gateway gates. The shared archive format makes this a
   one-command migration each way, and smolvm remains the rollback.
4. When confident: port `import-hermes`/`extract`/full archive validation,
   move `tests/` fixtures from a fake `smolvm` to a fake `docker`, then
   retire the smolvm path.
