# hermes-box-lite

Small, isolated agent VMs with **Claude Code, Codex, Hermes, and Executor**.
Each box runs on [smolvm](https://smolmachines.com), has no host filesystem
mounts, and keeps portable user state under `/data`.

[Usage guide and quick start](docs/usage-guide.html)

This is deliberately simpler than full Hermes Box: there are no release locks,
offline artifact closures, or transactional component updates. The reliability
boundary is narrower: safe lifecycle operations and verified state backups.

## Model

```text
./box new alpha
      │  Ubuntu VM + pinned Hermes runtime
      ▼
  smolvm "alpha"
      │  managed tools: /opt/hermes-box and /usr/local
      │  portable state: /data/home/agent
      │    .claude · .codex · .hermes · .executor · workspace · XDG state
      │
      │  ./box save alpha
      ▼
  backups/alpha-<timestamp>.tar.gz.gpg
      encrypted, validated state archive plus runtime-version manifest
```

The VM protects the host filesystem. Networking is always enabled because
provisioning and the agent tools require internet access. Tools inside one box
share the `agent` account, credentials, network, and passwordless guest sudo;
they are one trust domain.

`/data` is an organizational boundary on the VM's persistent root overlay, not
a separate virtual disk. Deleting or losing the VM loses live state, so keep
current backups for anything important.

## Quick start

Host prerequisites:

- macOS with the smolvm-supported virtualization stack, or Linux on x86_64 or
  arm64 with KVM available and the current user allowed to access `/dev/kvm`;
- `smolvm`, GPG, curl, jq, tar, awk, and standard Bash command-line tools; and
- a graphical opener for `box open` (`open` on macOS, or `xdg-open`/`gio` on
  Linux). On another desktop, set `BOX_BROWSER` to a graphical opener. It
  receives the secret authenticated URL directly as its sole argument, so do
  not use a wrapper that logs arguments.

On Linux, verify KVM access before creating a box:

```bash
test -r /dev/kvm -a -w /dev/kvm
smolvm machine ls
```

```bash
./box new alpha
./box doctor alpha
./box enter alpha
# Inside: hermes setup --portal, claude, codex
# After setup and single-writer gates, use the confirmed gateway-enable command below.

./box open alpha
./box save alpha

# Restore elsewhere. The archive is decrypted and validated before a VM is made.
./box load backups/alpha-20260625-120000.tar.gz.gpg beta

# Import a native backup from another Hermes host. Gateway remains disabled.
./box import-hermes beta /staging/hermes-backup.zip --map /Users/davis=/data/home/agent
```

Set `BOX_PASSPHRASE` for unattended encryption/decryption. Otherwise GPG
passphrases are read from the terminal without echo.

## Commands

| Command | Behavior |
|---|---|
| `box new <name>` | Create, provision, wire MCP, and health-check a box; attempt verified cleanup on failure |
| `box enter <name>` | Log in as `agent` and attach persistent tmux session `main` |
| `box ls [--all]` | List managed boxes, or every smolvm VM |
| `box open <name>` | Open the authenticated Executor UI without printing its token |
| `box doctor <name>` | Read-only health check; deliberate quiescence is reported without resuming services |
| `box repair <name>` | Re-run provisioning, refresh managed assets, and re-check health |
| `box stop` / `start <name>` | Stop or start a VM under a per-box mutation lock |
| `box save <name> [out]` | Pause Executor, archive `/data`, validate, encrypt, and verify without overwriting |
| `box load <file> [name]` | Validate first, provision a clean VM, restore while Executor is paused, then verify |
| `box import-hermes <name> <zip> [--map OLD=NEW]` | Validate and atomically import native Hermes state; leave its gateway disabled |
| `box extract <file> [dir]` | Validate and extract an archive without creating a VM |
| `box rm <name> [--force]` | Show backup status and require exact-name confirmation unless forced |

Mutating commands use local lock directories so concurrent operations cannot
modify the same box or registry entry.

## Executor and MCP

Executor runs continuously on guest `127.0.0.1:4788`. If web exposure is
enabled, smolvm forwards a unique host-loopback port in the configured
`4790–4999` range. `box open` reads Executor's stable local token and hands the
authenticated URL directly to the browser without printing the credential.

`box open` launches a browser on the machine running `./box` itself (via
`BOX_BROWSER`, `xdg-open`, or `gio open`). On a headless host reached over SSH
or Tailscale rather than at its console, that handoff can report success
without any browser becoming visible to you — these openers consider the job
done once they hand the URL to a desktop session or portal, not once a human
sees a window. To reach the UI from a separate client machine instead, forward
the host-loopback port yourself, e.g. `ssh -L <port>:127.0.0.1:<port> <host>`,
read the live token from inside the box with `./box enter` then `hb
executor-token` (so it never touches host logs, shell history, or `box`'s own
output), and open `http://localhost:<port>/?_token=<token>` in a browser on
that client machine.

The workload keeps one Executor daemon alive. Claude and Codex connect to that
daemon's authenticated Streamable HTTP endpoint; they do not launch `executor
mcp` as a second process. The bearer token remains under `/data` in Executor's
mode-0600 auth file and a mode-0600 Codex environment file. Set
`WIRE_EXECUTOR_MCP=0` before provisioning to disable registration.

The guest doctor check—and the host check when web exposure is enabled—performs
a complete MCP handshake: it uses `jq` to validate the JSON `initialize`
result and negotiated protocol version, sends the
initialized notification, and closes the session best-effort. Requests have
bounded timeouts. A listening socket, malformed result, 404 page, or HTTP 500
response does not count as healthy. Without an exposed port, doctor explicitly
reports that the host endpoint check was skipped.

Hermes runs as a supervised foreground gateway alongside Executor. Fresh and
imported boxes begin with the gateway durably disabled, so setup and migration
cannot accidentally create a second Discord writer. Enable it explicitly only
after authentication or the final single-writer cutover. Inside a box:

```bash
hb status
hb doctor
hb versions
hb down       # durable pause; the workload will not immediately restart it
hb up
hb acknowledge-active-paths
hb cutover-ready
hb gateway-enable --confirm-single-writer I_CONFIRM_NO_OTHER_GATEWAY_USES_THIS_IDENTITY
hb gateway-disable
hb verify-state
hb wire-mcp   # replace stale/legacy wiring with authenticated HTTP MCP
hb logs executor
```

## Backup and restore guarantees

`box save`:

1. acquires the box mutation lock;
2. gracefully quiesces Hermes and Executor, waits for shutdown, checkpoints
   SQLite, and runs integrity checks;
3. atomically writes a mode-0600 runtime-version manifest at
   `~/.config/hermes-box/runtime-manifest` and archives `/data` inside the guest;
4. excludes caches, native dependency trees, checkpointed Hermes SQLite
   sidecars, PIDs, and locks while preserving unrelated `/data` database files,
   then copies the archive using `smolvm machine cp`;
5. validates its paths and required durable-home layout;
6. encrypts to a unique temporary destination;
7. decrypts and lists the encrypted result as a verification pass; and
8. publishes it without overwriting an existing backup.

Host and guest plaintext temporaries and operation locks are removed by exit
and signal traps. Guest plaintext is removed before services are selectively
resumed to their prior state, even
when a later save step fails. Do not actively edit workspace files during a
save; Executor is quiesced, but arbitrary editor or agent processes are not
frozen.

`box load` decrypts and validates before spending time or creating resources.
It restores while Executor is paused, removes hidden as well as normal old
state into staging, verifies databases before the swap, refreshes
repository-owned guest assets, keeps the Hermes gateway disabled, starts a fresh
Executor daemon, repairs MCP wiring, and runs the doctor. A failed new or
load operation—including interruption by HUP, INT, or TERM—attempts to remove
only an incomplete destination VM proven to have been created by that
invocation. Registry metadata is removed only after VM absence is verified. If
cleanup cannot delete the VM or acquire the registry lock, it preserves
metadata and prints recovery guidance. An unmanaged or ambiguous same-named
smolvm machine is never deleted.

Backups are state-portable, not VM images. Hermes itself is pinned by full Git
SHA and rebuilt for the guest architecture. Ubuntu, Claude, Codex, and Executor
packages can still drift; the runtime manifest records their versions.

Native `hermes backup` imports add ZIP traversal/symlink validation, staging and
duplicate normalized-path rejection, atomic swap, SQLite integrity and inventory
baselines, and active-file-only path
rewrites. Historical sessions, memories, databases, and logs are not rewritten.
Validation also requires an importable canonical root Hermes marker after all
skip rules, so a transient-only archive cannot replace existing state with an
empty home.
The source ZIP is opened read-only and remains unchanged. Root-level
`~/.hermes/tmp` content and otherwise importable files with thin Mach-O magic or
a structurally valid universal Mach-O header are deterministically skipped
before staging, including beneath approved external provider trees. The fat
header validation distinguishes the shared `CAFEBABE` prefix from portable Java
class files. A successful import with exclusions emits a warning and records
exact skipped paths, byte counts, reasons, and normalized file/byte totals in
the import manifest; it does not silently treat macOS binaries as portable.
External provider state is previewed and rejected unless the operator explicitly
approves every safe top-level destination with repeatable `--external NAME`
flags; reserved destinations such as `.ssh`, `.config`, and shell startup files
are never imported. Ordinary supplemental trees remain separate.
See [Nexus operations and Eventide migration](docs/nexus-operations.md) for the
host systemd units, scheduled encrypted backups, NAS rules, and cutover gates.

## Tool installation and state

| Tool | Installation | Durable state |
|---|---|---|
| Claude Code | current npm package under `/opt/hermes-box` | `~/.claude` |
| Codex | current npm package under `/opt/hermes-box` | `~/.codex` |
| Hermes | official installer at `HERMES_GIT_SHA`, optionally seeded by a local Git bundle | `~/.hermes` |
| Executor | current npm package under `/opt/hermes-box` | `~/.executor` plus XDG directories |
| Neovim | Ubuntu package | XDG config/data/state |

Configuration lives in `box.env`. The provisioning script installs a root-owned
copy at `/etc/hermes-box.env`, so guest helpers honor `INSTALL_HERMES`,
`INSTALL_EXECUTOR`, `EXECUTOR_PORT`, and `WIRE_EXECUTOR_MCP` consistently.
New boxes default to 4 CPUs, 8 GiB memory, and a configurable 64 GiB overlay.
Optional Hermes API forwarding is disabled by default and uses per-box,
collision-checked loopback ports when enabled. Registry rows remain compatible
with legacy two-column entries.

## Local validation

```bash
make check
```

This requires ShellCheck, Python 3, and jq, and runs Bash syntax checks, static
contract checks, protocol-health regressions, and local archive/lifecycle smoke
tests. It does not create a VM or contact upstream installers. `make check` is
fully hermetic, so `.depot/workflows/check.yml` runs it on every push and
pull request to `main` via Depot CI.

If `./box new` fails immediately with "Hermes installer checksum verification
failed", upstream has rotated `install.sh` since `HERMES_INSTALLER_SHA256` was
last pinned. Run `make check-hermes-pin` (needs network access, so it's not
part of `make check`) to confirm the drift, review the new installer, then
update `box.env` yourself — this check does not auto-update the pin.
