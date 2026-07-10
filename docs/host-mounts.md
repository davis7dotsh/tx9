# Host mounts

TX9 can expose a host directory or a host-mounted NAS share inside one box's
agent container. The host remains responsible for mounting the filesystem and
for its credentials; TX9 stores only the source path, container target, and
access policy.

## Add the Nexus agents share to `media-bot`

Mount the NAS on the host first, then add it to the box:

```bash
findmnt --target "$HOME/agents"
tx9 mount add media-bot "$HOME/agents" /mnt/agents --require-mountpoint
tx9 mount list media-bot
```

The default is read/write. Add `--read-only` when the agent should only consume
the data:

```bash
tx9 mount add media-bot "$HOME/agents" /mnt/agents \
  --require-mountpoint --read-only
```

`mount add` recreates only the disposable agent container. It does not remove
or rewrite the agent's durable `/data` volume, its Executor container, or
either container's named volume. If the box was running, TX9 starts the new
agent container and runs the normal readiness checks.

TX9 records the desired mount in `~/.tx9/boxes/<box>.env`. A later
`tx9 upgrade <box>` reapplies it automatically. A portable `.tx9` backup does
not contain this host-local configuration; add the appropriate host mounts
after importing a box on another machine.

## Why targets live below `/mnt`

`tx9 backup` archives the agent's `/data` volume. External mounts must target a
child of `/mnt` so a backup cannot accidentally walk a NAS, copy a large media
library into the box archive, or make restores depend on host storage.

The mounted files are still fully visible to the free-rein agent container.
Read/write mounts let the agent modify or delete host data, so use
`--read-only` unless writes are intentional.

## NAS safety and permissions

Use `--require-mountpoint` for network storage. Before every add, remove, or
upgrade, TX9 verifies that the exact source path appears in the host's mount
table. If the NAS is unavailable, TX9 stops before removing a container
instead of binding the empty directory underneath the missing mount. Because
`mount remove` recreates the agent with the remaining desired mounts, an
offline `--require-mountpoint` source can also block removing a *different*
mount until the share is back (or removed first).

NAS mounts commonly map all files to the host user's numeric group. TX9 checks
the source directory permissions and adds the required non-root host GID as a
supplemental group inside the agent container. This is why a share owned by
host GID 1000 remains accessible to TX9's agent user even though the agent's
primary UID/GID is 1001.

The host mount itself must persist across reboots and be available before the
agent container starts. On Linux, a systemd `.mount`/`.automount` unit or an
equivalent `_netdev` mount is preferable to an interactive desktop mount.

## Inspect or remove mounts

```bash
tx9 mount list media-bot
tx9 mount remove media-bot /mnt/agents
```

Removal updates the desired state and recreates only the agent container, just
like addition. Removing a TX9 mount never unmounts the source on the host.
