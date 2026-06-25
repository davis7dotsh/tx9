# hermes-box-lite

Small, isolated agent VMs with **Claude Code, Codex, Hermes, and Executor**.
Each box runs on [smolvm](https://smolmachines.com), has no host filesystem
mounts, and keeps portable user state under `/data`.

**[Usage guide and quick start](https://columbia-pages.davis7.sh/p/5UcuYS0y4E79)**

This is deliberately simpler than full Hermes Box: there are no release locks,
offline artifact closures, or transactional component updates. The reliability
boundary is narrower: safe lifecycle operations and verified state backups.

## Model

```text
./box new alpha
      │  Ubuntu VM + current toolchain
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

```bash
./box new alpha
./box doctor alpha
./box enter alpha
# Inside: hermes setup --portal, claude, codex

./box open alpha
./box save alpha

# Restore elsewhere. The archive is decrypted and validated before a VM is made.
./box load backups/alpha-20260625-120000.tar.gz.gpg beta
```

Set `BOX_PASSPHRASE` for unattended encryption/decryption. Otherwise GPG
passphrases are read from the terminal without echo.

## Commands

| Command | Behavior |
|---|---|
| `box new <name>` | Create, provision, wire MCP, and health-check a box; remove it on failure |
| `box enter <name>` | Log in as `agent` and attach persistent tmux session `main` |
| `box ls [--all]` | List managed boxes, or every smolvm VM |
| `box open <name>` | Open the authenticated Executor UI without printing its token |
| `box doctor <name>` | Check required tools, Executor/MCP health, durable state, and host forwarding |
| `box repair <name>` | Re-run provisioning, refresh managed assets, and re-check health |
| `box stop` / `start <name>` | Stop or start a VM under a per-box mutation lock |
| `box save <name> [out]` | Pause Executor, archive `/data`, validate, encrypt, and verify without overwriting |
| `box load <file> [name]` | Validate first, provision a clean VM, restore while Executor is paused, then verify |
| `box extract <file> [dir]` | Validate and extract an archive without creating a VM |
| `box rm <name> [--force]` | Show backup status and require exact-name confirmation unless forced |

Mutating commands use local lock directories so concurrent operations cannot
modify the same box or registry entry.

## Executor and MCP

Executor runs continuously on guest `127.0.0.1:4788`. If web exposure is
enabled, smolvm forwards a unique host-loopback port in the configured
`4790–4999` range. `box open` reads Executor's stable local token and hands the
authenticated URL directly to the browser without printing the credential.

The workload keeps one Executor daemon alive. Claude and Codex connect to that
daemon's authenticated Streamable HTTP endpoint; they do not launch `executor
mcp` as a second process. The bearer token remains under `/data` in Executor's
mode-0600 auth file and a mode-0600 Codex environment file. Set
`WIRE_EXECUTOR_MCP=0` before provisioning to disable registration.

Inside a box:

```bash
hb status
hb doctor
hb versions
hb down       # durable pause; the workload will not immediately restart it
hb up
hb wire-mcp   # replace stale/legacy wiring with authenticated HTTP MCP
hb logs executor
```

## Backup and restore guarantees

`box save`:

1. acquires the box mutation lock;
2. gracefully pauses Executor and waits for its port to close;
3. writes a runtime-version manifest and archives `/data` inside the guest;
4. copies the archive using `smolvm machine cp`;
5. validates its paths and required durable-home layout;
6. encrypts to a unique temporary destination;
7. decrypts and lists the encrypted result as a verification pass; and
8. publishes it without overwriting an existing backup.

Host plaintext temporaries and operation locks are removed by exit and signal
traps. Executor is resumed even when a later save step fails. Do not actively
edit workspace files during a save; Executor is quiesced, but arbitrary editor
or agent processes are not frozen.

`box load` decrypts and validates before spending time or creating resources.
It restores while Executor is paused, removes hidden as well as normal old
state, refreshes repository-owned guest assets, starts a fresh daemon against
the restored database, repairs MCP wiring, and runs the doctor. A failed new or
load operation removes its incomplete destination VM and registry entry.

Backups are state-portable, not reproducible machine images. Restoring later
provisions the then-current Ubuntu packages and upstream tool releases before
injecting saved state. The included runtime manifest helps diagnose version
drift but does not eliminate it.

## Tool installation and state

| Tool | Installation | Durable state |
|---|---|---|
| Claude Code | current npm package under `/opt/hermes-box` | `~/.claude` |
| Codex | current npm package under `/opt/hermes-box` | `~/.codex` |
| Hermes | official headless installer | `~/.hermes` |
| Executor | current npm package under `/opt/hermes-box` | `~/.executor` plus XDG directories |
| Neovim | Ubuntu package | XDG config/data/state |

Configuration lives in `box.env`. The provisioning script installs a root-owned
copy at `/etc/hermes-box.env`, so guest helpers honor `INSTALL_HERMES`,
`INSTALL_EXECUTOR`, `EXECUTOR_PORT`, and `WIRE_EXECUTOR_MCP` consistently.

## Local validation

```bash
make check
```

This runs Bash syntax checks, ShellCheck, static contract checks, and local
archive/lifecycle smoke tests. It does not create a VM or contact upstream
installers. There is intentionally no CI configuration yet.
