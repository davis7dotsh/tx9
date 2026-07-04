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

```text
./docker/boxd build          (once per box.env / pin change)
      │  provision.sh runs INSIDE `docker build`
      ▼
  image hermes-box-lite:latest
      │  managed tools: /opt/hermes-box and /usr/local — image layers, immutable
      │
./docker/boxd new alpha      (seconds)
      ▼
  container hbl-alpha  ←→  named volume hbl-alpha-data mounted at /data
      │  portable state: /data/home/agent (.claude · .codex · .hermes ·
      │  .executor · workspace · XDG state) — IDENTICAL layout to smolvm boxes
      │
./docker/boxd save alpha
      ▼
  backups/alpha-<ts>.tar.gz.gpg   — SAME format as ./box save; archives are
                                    interchangeable between the two runtimes
```

One box = one container + one named volume. The container is disposable
(recreate it from the image at any time); the volume is the box. This is a
sharper version of the smolvm story, where "/data" was only an organizational
boundary on the same overlay — here it is a genuinely separate object with its
own lifecycle, and `docker run --rm -v hbl-alpha-data:/data …` can operate on
state with no box running at all (used by `boxd load`).

### What stays exactly the same

- `provision/provision.sh` — unchanged, now a build step.
- `guest/` (hb, hb-workload, hermes-state, profiles, tmux) — unchanged.
  `hb-workload` runs as the container workload under a tiny entrypoint loop;
  its 20s reconcile of executor/gateway/socat bridges carries over verbatim.
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

This is the one real cost, and it should be stated plainly:

- smolvm: hardware virtualization; a kernel exploit in the box does not reach
  the host.
- Docker: shared kernel; isolation is namespaces + cgroups. The container runs
  agent workloads that execute arbitrary code (that's the product).

Mitigations, in order of value-for-effort:

1. Keep **no host bind mounts** (the draft already does this — named volumes
   only), so "the VM protects the host filesystem" degrades to "the container
   protects the host filesystem" rather than disappearing.
2. Run the workload as the non-root `agent` user (already the case); keep
   root only for PID-1 reconcile, or drop to `--user agent` +
   `sudo`-less design in a later pass.
3. Optional hardening flags in one place in `boxd`: `--security-opt
   no-new-privileges`, a seccomp profile, `--cap-drop ALL --cap-add` the few
   needed, `--pids-limit`, and (if desired later) gVisor/Kata as a drop-in
   `--runtime` for VM-grade isolation **without changing anything else in
   this design**. That's the escape hatch if the isolation trade ever bites:
   `--runtime=runsc` gets most of the VM boundary back and boxd doesn't care.

Networking stance is unchanged from smolvm (always-on, tools need internet),
so container networking is default bridge; only the two bridge ports are
published, bound to 0.0.0.0 so they're reachable over Tailscale.

## Lifecycle mapping

| smolvm (`./box`) | Docker (`boxd`) | Notes |
| --- | --- | --- |
| `new` (5–10 min) | `build` once + `new` (seconds) | build is the slow step, amortized |
| `enter` | `enter` | `docker exec -it -u agent bash -l` → same tmux attach |
| `ls` | `ls` | reads daemon state, no registry file |
| `doctor` | `doctor` | in-box `hb doctor` unchanged; host port checks TBD |
| `save` / `load` | `save` / `load` | same archive format; load restores into a fresh volume via a throwaway container, gateway disabled + quiesced on arrival |
| `repair` | `build` + recreate container | volume untouched; "repair" becomes "replace" |
| `import-hermes` | port later | pure `hermes-state` work; runtime-agnostic |
| `stop`/`start`/`rm` | same | `rm` deletes container **and** volume after typed confirmation |

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
