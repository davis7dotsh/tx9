# tx9 security model

tx9 separates the agent and Executor into different Docker containers. It
does **not** currently keep Executor credentials confidential from an agent
that holds the box's Executor token. Treat that token as administrator access,
not as permission to call only approved tools.

## The Executor token is an administrative capability

The reviewed Executor local daemon, version 1.6.0, uses one bearer token for
its API, MCP, and approval endpoints. All authenticated callers receive the
same local identity. Its built-in MCP plugin enables stdio servers, and the
authenticated server-management API can start a configured command inside
the Executor container. An agent with the token can therefore reach beyond
ordinary tool execution into Executor's own process and credential storage.

This follows the upstream local daemon's single-user design. The relevant
sources are its [authentication contract](https://github.com/UsefulSoftwareCo/executor/blob/v1.6.0/apps/local/src/auth.ts),
[identity provider](https://github.com/UsefulSoftwareCo/executor/blob/v1.6.0/apps/local/src/identity.ts),
[plugin configuration](https://github.com/UsefulSoftwareCo/executor/blob/v1.6.0/apps/local/executor.config.ts),
and [MCP server management](https://github.com/UsefulSoftwareCo/executor/blob/v1.6.0/packages/plugins/mcp/src/sdk/plugin.ts).

tx9 currently injects this same token into the agent to wire its MCP clients.
Changing only the container filesystem, published address, or stdio setting
does not create a restricted agent identity. A stronger design needs all of
the following:

- Keep the Executor administrator token out of the agent's environment,
  configuration, and portable backups.
- Give the agent a separate identity that reaches only an operator-selected
  set of tools. Block management APIs, approval APIs, and management tools
  reachable through MCP.
- Prevent the agent from reaching the unrestricted daemon by another network
  route. Check redirects, OAuth callbacks, streaming, and credential-bearing
  outbound requests at that boundary.

That change requires an explicit decision about whether agents may manage
integrations. It is not implemented by the audit fixes.

## What the containers separate

| Component | Access and limits |
| --- | --- |
| Host operator and Docker daemon | Trusted. Docker access can inspect container environments, enter either container, and mount either volume. |
| Agent | Has its own writable volume, internet access, passwordless sudo, explicitly configured host mounts, and the Executor token. Claude, Codex, Hermes, and custom services share this trust level. |
| Executor | Has a separate volume and process namespace. The agent does not receive this volume as a mount, but its API token grants the authority described above. |
| Log helper | Temporarily reads both volumes, mounted read-only. It has no network access, refuses symlink traversal and special files, and queries SQLite from private snapshots. Its output remains sensitive. |
| Restore helper | Has no network access and writes only the target box's agent volume after archive validation. |

Containers share the host kernel. tx9 does not configure a VM, gVisor,
rootless Docker, or a per-agent egress firewall. A private bridge isolates
direct container discovery; it does not prevent an agent from reaching the
host, LAN services, or another box's published Executor port. Docker's
[port-publishing and firewall rules](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
apply independently of per-box DNS names.

## Credentials and transport

Each box gets a random 256-bit token. Host state files use mode `0600`, and
new state directories use mode `0700`. Import mints a new Executor token.
Other provider credentials in the portable agent volume still travel with
the backup and remain readable by software running as the agent.

`tx9 open` produces a URL containing a persistent bearer token. The URL is
reusable, not a single-use login link. It can be retained in terminal output,
browser history, proxy logs, or the arguments of an explicitly configured
browser command. The default published endpoint uses HTTP on all host
interfaces. HTTPS and a loopback-only backend can be configured as described
in [the Executor HTTPS guide](tailscale-executor.md), but are not automatic.

The interactive backup password prompt avoids a passphrase in process
arguments. `--password` is supported for compatibility and exposes its value
in the caller's command line. `TX9_PASSWORD` also remains sensitive environment
state. Neither mechanism protects secrets from the host operator.

## Storage and logs

Archive validation rejects traversal, special files, unsafe links, and
ambiguous outer members. It limits metadata size, member count, and link
resolution depth. It is not an overall disk quota. Large valid archives or
log snapshots can still exhaust available storage.

Log database snapshots copy validated files without a live SQLite read
transaction. Concurrent writes can cause read failures or produce an export
that does not represent one consistent point in time.

Log redaction covers known token values and common credential formats,
including quoted values. It does not recognize every secret, encoding, or
private document. Native histories and `--no-redact` output may contain
credentials. Exported logs have mode `0600` and are not encrypted.

A host bind mount grants the agent access to its contents. Read-only mounts
prevent ordinary filesystem writes, not credential reads or communication
through Unix sockets in the mounted directory. Mounting a home directory,
Docker socket directory, or credential store can defeat the intended host
boundary. `--require-mountpoint` checks presence during mount configuration
and recreation; it is not continuous monitoring of a host filesystem.

## Updates

The CLI verifies downloaded binaries against release checksums over the
configured origin. This detects corrupted downloads, not compromise of the
origin that serves both binary and checksum. Native tool installers and
upstream package registries are also trusted during image provisioning.

Changing source dependencies or updating the CLI does not patch a running
box or the host's Docker daemon. Guest fixes require a newly built image and
box recreation. The host kernel, Docker daemon, and existing volume contents
remain outside the repository's automated dependency checks.
