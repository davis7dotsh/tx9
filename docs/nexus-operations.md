# Nexus operations and Eventide migration

This runbook moves one Hermes identity from Eventide into one tx9 VM on Nexus.
The safety rule is simple: Eventide remains the only live gateway until the
final delta is imported and explicitly enabled on Nexus.

## 1. Prepare Nexus

Nexus needs KVM, `smolvm`, GPG, jq, curl, tar, Python 3, and enough free disk
for the 64 GiB default overlay plus encrypted backup staging. Create a dedicated
non-login service account so boot does not depend on an interactive session:

```bash
sudo useradd --create-home --shell /usr/sbin/nologin tx9
sudo usermod -aG kvm tx9
sudo install -d -o tx9 -g tx9 -m 0700 /opt/tx9 /var/backups/tx9 /var/lib/tx9
sudo install -d -o root -g root -m 0755 /etc/tx9 /etc/tx9/boxes
sudo -u tx9 test -r /dev/kvm -a -w /dev/kvm
```

Install this checkout at `/opt/tx9`, owned by `tx9`, and run `make check`
before using it. Do not copy Eventide's macOS virtual environments,
`node_modules`, caches, launchd files, or ARM64 binaries.

For Eventide's custom runtime, create a complete Git bundle outside this repo,
copy it locally to ignored `artifacts/hermes-eventide.bundle`, and set both:

```bash
HERMES_GIT_SHA="b9e586ec7534fad49d6599a742830a0024cc0906"
HERMES_GIT_BUNDLE="artifacts/hermes-eventide.bundle"
```

The host and guest validate the bundle, the official installer rebuilds the
checkout and venv for Linux x86_64, and provisioning verifies the final HEAD.
The bundle must be self-contained: incremental bundles that depend on external
prerequisite objects are intentionally unsupported for offline reproducibility.
The checked-in default remains the known official SHA in `box.env`.

## 2. Install boot, health, and backup supervision

Review the units in `ops/systemd`, then install them without editing the repo:

```bash
sudo install -m 0644 ops/systemd/* /etc/systemd/system/
sudo install -m 0600 /path/to/local/passphrase /etc/tx9/backup-passphrase
sudo systemctl daemon-reload
```

Do not enable or start these units yet. First create the box, import state,
inspect the manifest and active paths, acknowledge them, and pass readiness.

The backup passphrase is delivered with systemd `LoadCredential`; it is not in
the unit's arguments or environment. `ops/tx9-host` publishes local backups as
`.partial`, writes a SHA-256 checksum, then atomically renames both. Optional NAS
copying is enabled in `/etc/tx9/boxes/hermes.conf`:

```bash
TX9_BACKUP_DIR=/var/backups/tx9
TX9_NAS_DIR=/mnt/davis-vault/tx9
```

The verified local encrypted backup is published first. When `TX9_NAS_DIR` is
set, replication then fails unless that path is an actual mountpoint; the local
backup remains available. Configure the CIFS mount separately as a systemd
automount and make it writable by `tx9`. Partial replication files are cleaned
on failure. Retention policy is intentionally left to the Nexus operator.

## 3. Stage a native Hermes backup

On Eventide, leave the gateway live for the first rehearsal and create a native
Hermes backup with `hermes backup`. Install the ZIP for the nologin account:

```bash
sudo install -o tx9 -g tx9 -m 0600 /incoming/hermes-backup.zip /var/lib/tx9/hermes-backup.zip
```

Supplemental trees
such as `~/brain`, `~/gbrain`, and `~/Developer/10xn.dev` are not part of the
Hermes import contract; copy them separately into `~/workspace` or another
documented durable path, then update active config references explicitly.

On Nexus:

```bash
sudo -u tx9 /opt/tx9/box new hermes
sudo -u tx9 python3 /opt/tx9/guest/hermes-state validate-zip \
  /var/lib/tx9/hermes-backup.zip | jq '.external_top_level_entries'
sudo -u tx9 /opt/tx9/box import-hermes hermes /var/lib/tx9/hermes-backup.zip \
  --external .honcho \
  --map /Users/davis=/data/home/agent
sudo -u tx9 /opt/tx9/box doctor hermes
```

The validation command is the no-mutation preview. Replace `.honcho` with the
exact safe names it reports and repeat `--external NAME` once per intended
provider. Import rejects any unapproved name and always rejects `.ssh`, broad
`.config` or `workspace`, and shell startup files. Do not approve a name merely
to make the command pass; confirm it belongs to the Eventide memory provider.

Import validates all ZIP paths and rejects symlinks before guest mutation. It
extracts to a sibling staging directory, verifies every SQLite database, applies
longest-first path rewrites only to active config, env, cron, hook, and script
files, then atomically swaps `~/.hermes`. Historical sessions, memories,
databases, and logs are never rewritten. The source ZIP is read-only.

Review inside the box:

```bash
hb status
hb verify-state
cat ~/.config/hermes-box/import-manifest.json
hb acknowledge-active-paths
hb cutover-ready
```

Only after that rehearsal state passes readiness, enable host persistence and
monitoring while the Hermes gateway itself remains disabled:

```bash
sudo systemctl enable --now tx9-box@hermes.service
sudo systemctl enable --now tx9-health@hermes.timer tx9-backup@hermes.timer
```

Health and backup units are ordered after the box service but do not require or
start it. Their helper checks that the smolvm machine is already running and
fails clearly when it is inactive, preserving deliberate stops.

After enabling supervision, manage the Nexus box lifecycle through systemd:

```bash
sudo systemctl stop tx9-box@hermes.service
sudo systemctl start tx9-box@hermes.service
```

Running `box stop hermes` directly while that supervisor is active is only a
temporary stop: the supervisor treats the loss as unexpected and starts it
again. A systemd-stopped box stays stopped; scheduled health and backup runs
then fail clearly and never restart it. Standalone boxes without the systemd
unit may continue to use the ordinary `box stop` and `box start` commands.

The manifest records source and destination SQLite integrity, `user_version`,
session/message table counts, session/memory/skill file inventories, cron totals,
Discord configuration presence, and rewritten files. Import leaves the Hermes
gateway disabled while Executor remains usable.

## 4. Single-writer cutover

1. Wait for Eventide to have no active agent work.
2. Stop and disable its Hermes gateway and watchdog. Confirm no gateway process,
   cron dispatcher, or Discord connection remains.
3. Create a final native `hermes backup` on Eventide and install it for `tx9`.
4. Preview the final ZIP's `external_top_level_entries` again, then re-run
   `box import-hermes` with explicit approvals for every intended provider, for
   example `--external .honcho`. This final single-writer import must include the
   intended external memory-provider state; never rely on rehearsal state.
5. Inspect the newly replaced, current import manifest and active paths. Compare
   its SQLite
   integrity `ok`, identical schema/user version, session/message counts, session
   files, memory files, and active cron jobs.
6. Verify active paths, provider credentials, custom CA files, MCP connectivity,
   and optional Hermes API configuration inside Nexus.
7. Run `hb acknowledge-active-paths`, then `hb cutover-ready` against that final
   import. Every import resets the acknowledgement, so the rehearsal's result
   cannot authorize the final delta.
8. Only then run `hb gateway-enable --confirm-single-writer
   I_CONFIRM_NO_OTHER_GATEWAY_USES_THIS_IDENTITY` inside the Nexus box. Here the
   phrase means Eventide is stopped and cannot reconnect with this Discord
   identity. Treat this as a
   startup request until `hb doctor` reports deep gateway health.
9. Run `box doctor hermes`, confirm exactly one gateway process, inspect
   `hb logs hermes`, send a Discord message in an existing thread, and verify it
   resumes prior context.
10. Reboot Nexus and confirm the box, gateway, health timer, and backup timer
   recover without login.

Do not enable the Nexus gateway while Eventide can still reconnect with the same
Discord token. Optional Hermes API forwarding is disabled by default; when
enabled, tx9 assigns collision-free loopback host and guest bridge ports and
shows the endpoint in `box ls`.

## 5. Rollback

Keep Eventide stopped and unchanged for at least seven days and two successful
Nexus backup cycles. To roll back, first disable and stop Nexus's gateway. If it
accepted new conversations, capture a fresh native backup before deciding how to
reconcile that new state. Start Eventide only after Nexus is confirmed offline.

Validate backups periodically by loading one into a disposable box. Restores are
verified while the gateway is disabled, so a rehearsal cannot claim the live
Discord identity accidentally.
