# tx9 audit & fix plan — 2026-06-30

Source: a live end-to-end test of `./box new` plus five parallel deep-read
audits (provisioning, the Hermes supervisor, the migration tool, ops/docs,
the test suite), run against commit `ded8e51` on `main`. No code was changed
during the audit; this document is the persisted plan for actually fixing
what it found. Each item below has a **Reproduce** section (how to see the
bug yourself) and a **Fix** section (the concrete steps to take). Items
marked "verified live" were actually triggered and root-caused against a
running VM; everything else is from direct code reading and is marked
accordingly.

Work through this top to bottom — P0 blocks everything else, since you can't
exercise most of P1–P3 if `box new` doesn't produce a working box.

---

## P0 — `./box new` is broken on a clean checkout (verified live, twice)

### P0-1: `HERMES_INSTALLER_SHA256` no longer matches upstream — DONE

**Symptom:** `./box new <name>` fails immediately with `Hermes installer
checksum verification failed`, right after provisioning prints
`hermes (official installer pinned to <sha>)`.

**Root cause:** `box.env:25` pins the SHA-256 of
`https://hermes-agent.nousresearch.com/install.sh`. Upstream has rotated that
script since the pin was set, so `provision/provision.sh:118` (`sha256sum
--check --status`) now correctly refuses to run the mismatched installer —
this is the safety check working as designed against stale, attacker-could-also-be-the-cause
drift, not a logic bug.

**Reproduce:**
```bash
grep HERMES_INSTALLER_SHA256 box.env
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | sha256sum
# the two hashes will not match
```

**Fix:**
1. Re-pin the hash to the current upstream script:
   ```bash
   live_sha=$(curl -fsSL https://hermes-agent.nousresearch.com/install.sh | sha256sum | awk '{print $1}')
   sed -i "s/^HERMES_INSTALLER_SHA256=.*/HERMES_INSTALLER_SHA256=\"$live_sha\"/" box.env
   ```
   Read the diff of `install.sh` against what's currently pinned (or at least skim it) before committing the new pin — this is the one unpinned-trust boundary in provisioning, so don't rubber-stamp it.
2. **Decide a maintenance story so this doesn't silently recur.** Options, cheapest first:
   - Add a `make check-hermes-pin` / `./box doctor-pins` target that fetches the live installer and diffs its hash against `box.env`, so drift is caught at `make check` time instead of at `box new` time for a real user.
   - Prefer `HERMES_GIT_BUNDLE` (already supported, see `box.env:38-39` and `provision/provision.sh:92-100`) for any host where reproducibility matters more than always-latest — a bundle pins exact bytes, a URL+hash pins bytes only until upstream moves the URL contents.
   - At minimum, add a comment at `box.env:23-25` noting the last-verified-against date so the next person knows how stale it might be.

---

### P0-2: `verify_required` silently kills provisioning via `set -e` (verified live, root-caused) — DONE

**Symptom:** Even after fixing P0-1, `./box new` still fails. The last
provisioning line printed is `verifying required tools`, then nothing — no
error message, no log line — followed immediately by `error: box creation
failed` and rollback. This happened on **both** of two independent live
attempts.

**Root cause — two stacked bugs in six lines (`provision/provision.sh:207-218`):**

```bash
verify_required() {
  log "verifying required tools"
  local cmd
  for cmd in node uv nvim claude codex; do
    command -v "$cmd" >/dev/null 2>&1 || { log "missing required tool: $cmd"; return 1; }
  done
  if [[ "${INSTALL_HERMES:-0}" == 1 ]]; then command -v hermes >/dev/null 2>&1; fi      # line 213
  if [[ "${INSTALL_EXECUTOR:-0}" == 1 ]]; then command -v executor >/dev/null 2>&1; fi  # line 214
  if [[ "${INSTALL_HERMES:-0}" == 1 ]]; then
    [[ "$(git -C /usr/local/lib/hermes-agent rev-parse HEAD)" == "${HERMES_GIT_SHA}" ]]
  fi
}
```

1. **`hermes` is never on `agent`'s PATH in the first place.** The upstream
   Hermes installer places its launcher at `~/.local/bin/hermes` — i.e.
   `/root/.local/bin/hermes`, since provisioning runs as root — not at
   `/usr/local/bin/hermes` as the comment at `provision/provision.sh:87-89`
   assumes. `/root/.local/bin` is never added to the `agent` user's PATH
   (`/opt/hermes-box/bin:/opt/hermes-box/tooling/node-global/bin:/opt/hermes-box/tooling/uv:...`,
   set in `guest/profile.sh`). So `command -v hermes` on line 213 genuinely
   fails — confirmed by direct inspection of a live VM:
   ```
   $ ls /root/.local/bin/hermes              # exists
   $ ls /usr/local/bin/hermes                # does not exist
   $ command -v hermes   # (as agent, with hermes-box.sh profile sourced)
   MISSING
   ```
2. **That failing command is inside an `if`-THEN body, not the `if`'s
   condition — and `set -e` (`provision/provision.sh:2`) does not exempt
   THEN-bodies, only conditions.** So the moment `command -v hermes` fails,
   the entire `provision.sh` process dies right there, silently, because
   nobody added `|| { log ...; return 1; }` the way the `node/uv/nvim/claude/codex`
   loop two lines above correctly does.
3. **Separately** (a second, independent bug in the same function): even if (1)/(2)
   didn't kill the script, `verify_required`'s actual return value is whatever
   its *last* statement returns — the `git rev-parse HEAD` check — so the
   `command -v hermes`/`command -v executor` checks on lines 213-214 were never
   going to gate success/failure even if they survived `set -e`. Two bugs, same
   six lines, masking each other.

**Reproduce (isolated repro, safe to run anywhere — does not touch a box):**
```bash
set -e
echo before
if [[ 1 == 1 ]]; then command -v hermes >/dev/null 2>&1; fi
echo "after (never prints — proves the silent-death mechanism)"
```

**Reproduce against the real installer (inside any fresh guest, after fixing P0-1):**
```bash
./box new tx9probe   # fails at "verifying required tools" with no further output
# .boxes / smolvm machine ls / .box-locks are all clean afterward — rollback itself is fine
```

**Fix — three separate edits, do all three:**

1. **Make `hermes` actually reachable on `agent`'s PATH.** In
   `install_hermes()` (`provision/provision.sh:78-150`), right after the
   `bash "$installer" ...` success branch and before `own_hermes_home` (around
   line 143), add an explicit symlink from wherever the installer really put
   the launcher into `$OPT/bin` (`/opt/hermes-box/bin`, already on `agent`'s
   PATH per `guest/profile.sh`):
   ```bash
   if [[ -x /root/.local/bin/hermes ]]; then
     ln -sf /root/.local/bin/hermes "$OPT/bin/hermes"
   fi
   ```
   Don't hardcode `/root` if you can avoid it — `$HOME` at this point in the
   script is root's home since the whole script runs as root, so
   `"$HOME/.local/bin/hermes"` is the more honest spelling. Verify this is
   still where the installer puts it before relying on it long-term (it's an
   upstream implementation detail, not a contract) — consider also checking
   `command -v hermes` *as the installer would have configured PATH* (it adds
   `~/.local/bin` to `/root/.bashrc`/`.profile`, per the installer's own
   output) as a fallback discovery mechanism rather than a single hardcoded
   path.
2. **Fix the line 87-89 comment** — it currently asserts a false contract
   (`binary -> /usr/local/bin/hermes`). Update it to describe reality once (1) is fixed.
3. **Give every check in `verify_required` explicit failure handling**, matching the style already used for `node/uv/nvim/claude/codex`:
   ```bash
   verify_required() {
     log "verifying required tools"
     local cmd
     for cmd in node uv nvim claude codex; do
       command -v "$cmd" >/dev/null 2>&1 || { log "missing required tool: $cmd"; return 1; }
     done
     if [[ "${INSTALL_HERMES:-0}" == 1 ]]; then
       command -v hermes >/dev/null 2>&1 || { log "missing required tool: hermes"; return 1; }
     fi
     if [[ "${INSTALL_EXECUTOR:-0}" == 1 ]]; then
       command -v executor >/dev/null 2>&1 || { log "missing required tool: executor"; return 1; }
     fi
     if [[ "${INSTALL_HERMES:-0}" == 1 ]]; then
       [[ "$(git -C /usr/local/lib/hermes-agent rev-parse HEAD)" == "${HERMES_GIT_SHA}" ]] || {
         log "Hermes checkout HEAD does not match pinned HERMES_GIT_SHA"; return 1;
       }
     fi
   }
   ```
   This doesn't just fix the silent-death bug — it also makes the function's
   pass/fail meaning correct (currently it can return success while `hermes`/
   `executor` are both missing, since the last-statement-wins return value
   ignores them entirely).

**Verification after fixing:** re-run `./box new tx9probe` end to end; confirm
it reaches `provision complete` and `Ready. Enter with: ./box enter tx9probe`,
then `./box doctor tx9probe` passes, then `./box rm tx9probe --force`.

---

### P0-3: a failed `box new` destroys the only evidence of why

**Symptom:** Both live failures above produced exactly one line of
explanation (`error: box creation failed`) before `_rollback_created`
(`box:603-633`) deleted the VM. The rollback mechanism itself is excellent —
verified twice that it leaves zero orphaned VMs, registry entries, or
locks — but it also deletes the only place the real error lived.

**This is not a live-reproduced "bug" so much as a confirmed UX gap**: P0-1
and P0-2 were only diagnosable here because the audit ran the same failure
twice in a disposable copy and inspected the VM *before* letting rollback run
(by calling `_create_base`/`_provision_into`/`_prepare_runtime` directly and
skipping the trap-driven cleanup for one diagnostic run). A normal user has
no equivalent escape hatch.

**Fix:**
1. On a provisioning failure inside `cmd_new`/`cmd_load` (`box:635-650`,
   `box:707-774`), before `_rollback_created` runs, capture the tail of
   whatever guest-side log exists (or at minimum the output already streamed
   to the host terminal — consider tee-ing `_provision_into`'s output to a
   host-side `backups/.failed/<name>-<timestamp>.log` unconditionally, since
   the function already shells the whole provisioning transcript through the
   host process).
2. Add a `BOX_KEEP_ON_FAILURE=1` (or `./box new --keep-on-failure`) escape
   hatch that skips `_rollback_created` and instead prints the VM name plus
   `smolvm machine exec --name <name> -- ...` and `./box rm <name> --force`
   hints, for exactly this kind of investigation.
3. Make the final `die "box creation failed"` in `cmd_new` (`box:642`)
   include which of `_create_base` / `_provision_into` / `_prepare_runtime`
   failed — right now `! A || ! B || ! C` collapses all three into one
   message with no way to tell from the final line alone which stage broke.

---

## P1 — safety gaps in already-claimed guarantees

These were found by direct code reading (not live-triggered — they require
either real timing races or a real single-writer Discord setup to observe
directly). Each entry says how to construct the race/condition if you want
to confirm it before fixing.

### P1-1: gateway can be double-spawned (race in `hb`/`hb-workload`)

**Files:** `guest/hb:74-88` (`_start_gateway`), `guest/hb-workload:67-96`
(`reconcile_once`, called every 20s by `guest/hb-workload:100-104`'s loop).

**Problem:** `_start_gateway` checks `_gateway_running` (`guest/hb:78`), and
if not running, spawns `hermes gateway run --replace` and writes
`$GATEWAY_PID` (`guest/hb:85-87`) — with no lock between the check and the
spawn. `hb-workload` calls `hb reconcile` → `_start_gateway` on a 20-second
timer (`guest/hb-workload:80`, `guest/hb:97-102`), and a host-initiated
`./box <cmd>` can call `_guest_hb "$n" up` (→ `_start_gateway`) at the same
moment (e.g. `cmd_open`/`box:926`, `_prepare_runtime`/`box:596-601`,
`cmd_repair`/`box:1008-1009`). Two processes can both observe "not running"
and both exec `hermes gateway run --replace`, which directly contradicts the
single-writer guarantee the whole `hb gateway-enable
--confirm-single-writer ...` ceremony (`docs/nexus-operations.md` §4) exists
to protect.

**Reproduce (construct the race deliberately):**
```bash
# inside a box, as agent, with INSTALL_HERMES=1 and gateway enabled:
for i in 1 2; do hb up & done; wait
pgrep -f '[h]ermes( .*)? gateway run' | wc -l   # may show 2, not 1
```
(Timing-dependent — may need a few attempts, or insert a `sleep 0.5` between
the `_gateway_running` check and the `nohup hermes gateway run` line in a
local copy of `hb` to make the window reliably wide.)

**Fix:**
1. Add a lock file (the same `mkdir`-based pattern `box` already uses for
   `_try_acquire_lock`, `box:143-171`) around `_start_gateway`'s
   check-then-spawn in `guest/hb:74-88`, e.g. `STATE_DIR/gateway.lock` —
   `mkdir` it before the `_gateway_running` check, release after writing
   `$GATEWAY_PID` or on early return.
2. Apply the same lock inside `reconcile_once` (`guest/hb-workload:67-96`)
   before it calls `hb reconcile`, or simply rely on (1) since `hb reconcile`
   already calls into `_start_gateway`.

### P1-2: `hb-workload` itself is unsupervised

**File:** `guest/hb-workload:98-105` (`main`), invoked once at boot by
`box:546-547`'s `smolvm machine create` command line.

**Problem:** If the `hb-workload` *loop process* dies (not the gateway or
Executor it manages — the bash loop itself, e.g. OOM-killed, or a bug in
`reconcile_once` that isn't guarded by the `set -u` mode it runs under),
nothing restarts it. Whatever state Hermes/Executor were in at that moment
persists unmanaged until the VM reboots — no more health reconciliation, no
more bridge socat processes being restarted if they die.

**Reproduce (code reading is enough to confirm; to observe live):**
```bash
# inside the box:
pkill -f 'hb-workload 4788'   # or whatever port; find via ps aux
sleep 25
ps aux | grep hb-workload     # nothing respawns it
```

**Fix:** Wrap the boot command in `_create_base` (`box:546-547`) in a
restart loop, e.g. change:
```bash
exec runuser -u agent -- env HOME=/data/home/agent /opt/hermes-box/bin/hb-workload ${wl_port} ${api_guest_port:-0}
```
to a `while true; do runuser ... hb-workload ...; sleep 2; done` (drop the
`exec` so the outer loop can restart it), or rely on smolvm's own
process-1-exits-VM-stops semantics plus a *systemd inside the guest* unit —
the latter is more in keeping with the project's existing host-side systemd
pattern (`ops/systemd/`), but the cheap fix is the restart loop.

### P1-3: `gateway_is_disabled()` checks a marker file, not process state

**Files:** `guest/hb:143` (`gateway_is_disabled() { [[ -e "$GATEWAY_DISABLED" ]]; }`),
consumed by `box:980-989` (`cmd_doctor`'s "host Hermes API: intentionally
disabled" branch) and `box:965` (`_guest_hb "$n" gateway-is-disabled`).

**Problem:** If `gateway_enable` (`guest/hb:145-160`) spawns
`hermes gateway run --replace` via `_start_gateway` and *then* something
later in that call path fails before `gateway_enable` returns, the marker is
re-touched as disabled (`guest/hb:156`) but there's no verification the
already-spawned process was actually killed first. `box doctor` would then
report "intentionally disabled" while a real gateway process is alive.

**Reproduce (requires deliberately injecting a failure after spawn — code
reading confirms the gap; to force it, patch a local copy of `hb` to `return 1`
unconditionally right after the `_start_gateway` call in `gateway_enable` and
observe that the spawned `hermes gateway run` process is never reaped):**
```bash
# after gateway_enable's _start_gateway call but with the call patched to always fail downstream:
pgrep -f '[h]ermes( .*)? gateway run'   # still running
hb gateway-is-disabled; echo $?          # reports "disabled" (marker says so) — true positive case for the gap
```

**Fix:** Make `gateway_is_disabled()` check both the marker *and* the
absence of a running gateway process:
```bash
gateway_is_disabled() { [[ -e "$GATEWAY_DISABLED" ]] && ! _gateway_running; }
```
And in `gateway_enable`'s failure path (`guest/hb:155-158`), explicitly call
`_stop_gateway` before re-touching `$GATEWAY_DISABLED`, rather than assuming
the marker alone is sufficient:
```bash
if ! _start_gateway; then
  _stop_gateway || true
  touch "$GATEWAY_DISABLED"
  return 1
fi
```

### P1-4: agent tooling versions are unpinned

**Files:** `provision/provision.sh:68-69` (`npm install -g @anthropic-ai/claude-code`),
`:74-75` (`@openai/codex`), `:163-165` (`executor`) — none specify a version.

**Problem:** Every `box new`/`box repair` (full mode) installs whatever is
currently `latest` on the npm registry. Two boxes created a week apart, or
the same box before/after a `repair`, can silently end up running different
Claude Code/Codex/Executor versions — with no `box.env` knob to pin, and
(per P0 fix above) no required version check to catch a breaking upstream
release before it reaches a real box.

**Reproduce:** `npm view @anthropic-ai/claude-code version` today vs. a week
from now will differ; nothing in this repo records what version a given box
was actually provisioned with beyond the free-text `runtime-manifest`
(`guest/hb:257-275`, written *after the fact*, not a pin).

**Fix:**
1. Add `CLAUDE_CODE_VERSION`, `CODEX_VERSION`, `EXECUTOR_VERSION` to
   `box.env` (empty default = latest, for backward compatibility), and use
   them in `provision/provision.sh:68-76,163-165`:
   ```bash
   npm install -g "@anthropic-ai/claude-code${CLAUDE_CODE_VERSION:+@$CLAUDE_CODE_VERSION}"
   ```
2. `guest/hb:write_manifest` (`guest/hb:257-275`) already records installed
   versions after the fact — keep that, but it's not a substitute for being
   able to *reproduce* a box; the pin is what makes `box new` deterministic.

### P1-5: decompression-bomb gate trusts declared size, not actual bytes — DONE

**File:** `guest/hermes-state:33` (`MAX_UNCOMPRESSED = 100 * 1024**3`),
gate at `:85-87` inside `_zip_layout`, extraction at `:389-413` (`_extract`,
streaming via `shutil.copyfileobj` at line 413 with no running byte-count
cap).

**Problem:** The 100 GiB gate sums `info.file_size` (`:85`) — the ZIP central
directory's *declared* uncompressed size, which is attacker-controlled
metadata. Python's `zipfile` doesn't cross-validate central-directory size
against what the local file header / deflate stream actually produces. A
crafted archive can declare a small `file_size` while its real decompressed
output is far larger; `_extract`'s `shutil.copyfileobj` (`:413`) streams
without checking actual bytes written against any limit, so the stated 100
GiB safety limit can be bypassed by a header/stream mismatch.

**Reproduce:** Construct a ZIP entry whose local file header advertises a
small `file_size` but whose compressed stream, when inflated, produces far
more data than declared (standard zip-bomb construction techniques — `pip
install zipfile36`-style manual entry crafting, or simpler: a deflate stream
with a very high compression ratio for highly repetitive data, declared at a
deliberately understated size in a hand-edited central directory record).
Run `python3 guest/hermes-state validate-zip crafted.zip` — it should pass
the 100 GiB check despite the real payload being enormous, then `import-zip`
would extract the full payload.

**Fix:** In `_extract` (`guest/hermes-state:389-413`), track actual bytes
written during `shutil.copyfileobj` and abort once a hard cap is exceeded —
e.g. read in `length=1024*1024` chunks manually (replacing the single
`copyfileobj` call) and increment a running total, raising once it exceeds
`MAX_UNCOMPRESSED` regardless of what the central directory claimed:
```python
written = 0
while True:
    chunk = source.read(1024 * 1024)
    if not chunk:
        break
    written += len(chunk)
    if written > MAX_UNCOMPRESSED:
        raise ValueError(f"archive member exceeds the uncompressed safety limit: {info.filename}")
    destination.write(chunk)
```

---

## P2 — repair/coverage gaps (code reading; no live repro needed beyond running the commands described)

### P2-1: `box repair` (assets mode) can't heal a failed Hermes/Executor install

**Files:** `provision/provision.sh:220-227` (`assets_only`). Note `cmd_repair`
(`box:994-1012`) always calls `_provision_into "$n" full`, never `assets` —
the only current caller of `assets` mode is `cmd_load`'s post-restore step
(`box:767`, `_provision_into "$n" assets`).

**Problem:** `assets_only()` only runs `make_agent`, `install_config`,
`place_assets`, `seed_data`, and `write-manifest` — it never calls
`install_hermes`, `install_executor`, or `verify_required`. A box whose
Hermes or Executor install failed or is missing can only be fixed by
re-running the **full**, multi-minute reinstall path; there's no cheap
"retry just the broken piece" repair.

**Reproduce:** On a box where `hermes`/`executor` are missing (e.g. one that
hit P0-2 before the fix, if rollback were disabled), run whatever invokes
`assets` mode and confirm `hermes`/`executor` remain missing afterward.

**Fix:** Add idempotent guards to `install_hermes`/`install_executor` (skip
reinstall if already present and `git rev-parse HEAD` matches, like
`verify_required` already checks) and call them unconditionally from
`assets_only`, immediately after `make_agent`. This makes `assets` mode a
true "fix what's missing" repair instead of "config files only."

### P2-2: zero test coverage for five of thirteen `box` subcommands

**Files:** `box:889-1052` (`cmd_ls`, `cmd_open` partially, `cmd_rm`,
`cmd_stop`, `cmd_start`, `cmd_enter`) vs. `tests/{static,lifecycle-smoke,hermes-state,regressions}.sh`.

**Problem:** Grep for these command names across all four test files returns
zero hits for `box ls`, `box rm`, `box enter`, `box stop`, `box start` —
these are the most frequently run day-to-day commands and have no coverage
at all, alongside untested code paths in already-tested commands: the
`_assign_port` retry/exhaustion loop (`box:302-311`), control-character
archive-path rejection (`box:378-380`'s `safe_text()`), and true per-box
(non-`registry`) lock contention (`_try_acquire_lock`, `box:143-171`).

**Fix (add to `tests/lifecycle-smoke.sh` or a new `tests/cli-surface.sh`):**
1. `box ls` / `box ls --all` against the fake `smolvm` fixture — currently
   the fixture doesn't even implement bare `machine ls` (falls through to
   `exit 2`); fix the fixture (`tests/fixtures/smolvm`) alongside the test.
2. `box rm <name>` — interactive confirmation (feed `expect`-style stdin via
   `/dev/tty` redirection or test the `--force` path), plus the "type the
   name to confirm" mismatch-refusal case.
3. `box stop`/`box start` — trivial wrappers, but assert the lock-then-delegate
   pattern still holds (a held lock should block a concurrent `stop`).
4. `box enter` — at minimum assert it `exec`s the right `smolvm machine exec
   -it ... -- login -f agent` command line against the fixture (can't fully
   test an interactive login).
5. Force `_assign_port`'s exhaustion path by pre-registering enough fake
   ports across the configured range to leave zero free, and assert the `die
   "no free host port in ${lo}-${hi}"` message.
6. Generate an archive member with a control character in its name/linkname
   and confirm `_validate_archive` rejects it (extend the existing fixture
   generator in `tests/lifecycle-smoke.sh`, which already covers eleven other
   cases there).

### P2-3: no CI

**Files:** `README.md:228` and `tests/static.sh:129` both assert
`"intentionally no CI configuration yet"` (the latter as a literal grep
check pinning that exact string).

**Problem:** `make check` (`Makefile:21`) is fast and fully hermetic — the
`tests/fixtures/smolvm` stub means no real VM/KVM/network access is needed —
so there's no technical blocker to running it in CI. Every regression this
otherwise-strong suite catches currently depends on a human remembering to
run `make check` locally before merging.

**Fix:**
1. Add `.github/workflows/check.yml` running `make check` (needs `python3`,
   `jq`, `shellcheck` for `make check`'s `lint` target — install via the
   workflow's package step) on push/PR to `main`.
2. Update the `README.md:228` / `tests/static.sh:129` pinned string once CI
   exists, since that test will otherwise correctly start failing the moment
   CI is added (which is by design — don't quietly delete that assertion;
   update what it asserts).

### P2-4: `tests/regressions.sh` structure and shared-helper duplication

**File:** `tests/regressions.sh` (1131 lines, ~10 unrelated concern areas in
one flat file — host-preflight checks, `tx9-host` supervise/backup behavior,
provisioning ownership, restore permissions, `hb-workload` reconcile/bridge
logic, gateway enable/disable, doctor/MCP health (~250 lines), registry/lock/
rollback races (~300 lines), save/restore failure injection).

**Problem:** A single failing assertion requires scanning up to 1131 lines
for context. The `mktemp -d` + `trap ... EXIT HUP INT TERM` cleanup
boilerplate is independently reimplemented in `tests/lifecycle-smoke.sh:5-7`,
`tests/hermes-state.sh:5-6`, and `tests/regressions.sh:6-30` — the third one
notably more elaborate (a `cleaned_up` guard plus explicit signal-to-exit-code
mapping) — with no shared file all four source. `make_repo()`
(`tests/regressions.sh:816-821`) is duplicated inline at
`tests/lifecycle-smoke.sh:219-221`.

**Fix:**
1. Extract a `tests/lib.sh` with the shared tempdir+trap+`make_repo` helpers,
   sourced by all four test files, with one canonical signal-to-exit-code
   mapping that matches `box`'s own contract (129/130/143).
2. Split `tests/regressions.sh` by concern, e.g.
   `tests/regressions-lock-rollback.sh`, `tests/regressions-doctor-mcp.sh`,
   `tests/regressions-hb-workload.sh`, `tests/regressions-tx9-host.sh` — update
   `Makefile`'s `test` target to glob `tests/regressions-*.sh` instead of one
   file, so new categories don't require touching the Makefile.

---

## P3 — polish and drift prevention

### P3-1: `box.env:36` hardcodes a personal path as the committed default

```
HERMES_IMPORT_PATH_MAP="/Users/davis=/data/home/agent"
```

**Problem:** This is Davis-specific (macOS username `davis`) and ships as the
*default* in version control. Anyone else cloning this repo gets a path
mapping that's wrong for them, with nothing in the README or
`docs/nexus-operations.md` flagging it as "change this first."

**Fix:** Either leave it empty by default and document that operators must
set it (the `import-hermes` flow already supports `--map OLD=NEW` per-invocation,
per `box:786-787`, so a non-empty default isn't structurally required), or
move this specific value into `docs/nexus-operations.md`'s migration runbook
(where it's already referenced) and out of the generic `box.env` template.

### P3-2: no systemd hardening directives on any of the four host units

**Files:** `ops/systemd/tx9-box@.service`, `tx9-health@.service`,
`tx9-backup@.service` (all reviewed in full).

**Problem:** All three run as the unprivileged `tx9` user (good — no
unnecessary root), but none set `NoNewPrivileges=true`, `ProtectHome=true`,
`ProtectSystem=strict` (or `full`), `PrivateTmp=true`, etc. Cheap, standard
hardening that costs nothing given what these units already don't need
(arbitrary filesystem write access outside `/opt/tx9`, `/var/backups/tx9`,
`/var/lib/tx9`).

**Fix:** Add to each `[Service]` block:
```ini
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
PrivateTmp=true
ReadWritePaths=/opt/tx9 /var/backups/tx9 /var/lib/tx9 /etc/tx9
```
Test each unit after adding (`systemctl daemon-reload && systemctl start
tx9-box@<name>.service` against a real or disposable box) since `ProtectSystem=strict`
in particular can break things that aren't covered by `ReadWritePaths` — KVM
device access (`/dev/kvm`) in particular needs verifying it isn't blocked.

### P3-3: NAS automount and backup retention are documentation only

**File:** `docs/nexus-operations.md:69-73` describes both; nothing in
`ops/` implements either (confirmed: no `.mount`/`.automount` unit, no
pruning script or `tmpfiles.d` rule anywhere in the repo).

**Fix:**
1. Ship `ops/systemd/mnt-davis\x2dvault\x2dtx9.automount` (or a generically-named
   template the operator renames) as a starting point for the CIFS mount
   `docs/nexus-operations.md:71` currently just describes in prose.
2. Add a retention script (`ops/tx9-backup-prune` or similar) — e.g. keep
   last N or last N-days of `backups/<name>-*.tar.gz.gpg` plus matching
   `.sha256` files — and a `tx9-backup-prune@.timer`/`.service` pair following
   the existing `ops/systemd/` naming convention. Without this, both
   `/var/backups/tx9` and any configured NAS target grow unbounded forever.

### P3-4: README and `docs/usage-guide.html` duplicate content with no single source of truth

**Files:** `README.md` (10,919 bytes) and `docs/usage-guide.html` — spot-checked
and currently consistent with actual `box` behavior, but the same command
table, env var table, and backup/restore guarantees prose exist independently
in both with no generation step tying them together.

**Fix:** Pick one canonical source (recommend the README, since it's what
renders on GitHub and what `tests/static.sh` already greps against) and
either (a) delete the duplicated sections from `usage-guide.html` in favor of
linking to the README, or (b) add a small generation step (e.g. a Python/
awk script that extracts the README's command table into the HTML at build
time) if the standalone HTML page needs to stay self-contained for offline
use.

---

## Suggested execution order

1. P0-1, P0-2 (unblocks everything else — without these, no box can be created to test anything downstream)
2. P0-3 (do this alongside P0-2 — you'll want the keep-on-failure escape hatch while fixing P1 items that need a real box to observe)
3. P1-1 through P1-5 (safety-bearing; each is independently shippable)
4. P2-3 (CI) as soon as P0/P1 land, so nothing regresses silently again
5. P2-1, P2-2, P2-4 (repair coverage, test coverage, test structure)
6. P3-1 through P3-4 (polish, no urgency, fine to batch into one PR)

Each numbered item above is scoped to be its own commit (or small group of
commits) against this branch.
