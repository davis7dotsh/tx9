# Tailscale HTTPS for Executor

Executor OAuth redirects need a stable browser-visible origin. A raw TX9
dashboard URL such as `http://100.x.y.z:32770` is not suitable for providers
that require an HTTPS callback, and Executor otherwise defaults its callback
origin to `http://localhost:4788` inside the container.

The supported TX9 setup is:

```text
browser on the tailnet
        |
        | https://<node>.<tailnet>.ts.net
        v
Tailscale Serve on the TX9 host
        |
        | http://127.0.0.1:<fixed-port>
        v
TX9 Executor container :4788
```

This keeps the dashboard private to the tailnet, gives it a publicly trusted
certificate, and gives Executor an exact origin for OAuth callbacks. Tailscale
Serve is a tailnet-only reverse proxy; do not use Funnel unless public internet
access is intentional.

## Configure an existing box

Run these commands on the TX9 host. Replace `media-bot` and the fixed port if
needed:

```bash
BOX=media-bot
PORT=32770
MAGICDNS=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
UPSTREAM_DNS=$(
  awk '/^nameserver / && $2 ~ /^[0-9]+\./ && $2 !~ /^127\./ { print $2; exit }' \
    /run/systemd/resolve/resolv.conf
)

test -n "$MAGICDNS"
test "$MAGICDNS" != null
test -n "$UPSTREAM_DNS"

tx9 upgrade "$BOX" \
  --executor-web-base-url "https://$MAGICDNS" \
  --executor-publish "127.0.0.1:$PORT" \
  --executor-dns "100.100.100.100,$UPSTREAM_DNS"

tailscale serve --bg --yes "http://127.0.0.1:$PORT"
```

Use `sudo tailscale ...` if the current account is not a Tailscale operator.
The first Serve command may open a Tailscale consent flow to enable HTTPS for
the tailnet.

The TX9 options have separate jobs:

- `--executor-web-base-url` becomes Executor's `EXECUTOR_WEB_BASE_URL`. It must
  be the exact origin loaded in the browser: scheme, hostname, and port when
  non-default. Executor derives `/api/oauth/callback` from it.
- `--executor-publish` gives Serve a stable loopback target. Loopback prevents
  clients from bypassing Serve and reaching the raw HTTP dashboard over LAN.
- `--executor-dns` gives the container both MagicDNS and ordinary DNS. The
  Tailscale resolver handles tailnet names; the host's upstream resolver keeps
  public OAuth and integration hosts working.

TX9 persists these values in `~/.tx9/boxes/<box>.env`. Future
`tx9 upgrade <box>` calls recreate the container with the same public origin,
port, and DNS settings, so the Serve target remains valid.

## Configure a new or imported box

The same options are accepted by `create` and `import`:

```bash
tx9 create media-bot \
  --executor-web-base-url "https://$MAGICDNS" \
  --executor-publish "127.0.0.1:$PORT" \
  --executor-dns "100.100.100.100,$UPSTREAM_DNS"

tailscale serve --bg --yes "http://127.0.0.1:$PORT"
```

For an import, replace `tx9 create ...` with `tx9 import backup.tx9 ...`.

## Validate the full path

Check the host proxy, HTTPS endpoint, and the actual Executor runtime:

```bash
tailscale serve status
tx9 list
curl -v "https://$MAGICDNS/api/health"

docker exec "tx9-$BOX-executor" \
  getent hosts "$MAGICDNS"
docker exec "tx9-$BOX-executor" \
  curl -fsS "https://$MAGICDNS/api/health"

tx9 doctor "$BOX"
```

Expected results:

- Serve maps `/` to `http://127.0.0.1:<fixed-port>`.
- `/api/health` returns `ok` over trusted HTTPS.
- `tx9 list` shows the HTTPS MagicDNS URL instead of a raw HTTP IP.
- `tx9 doctor` passes both the local port and configured public URL probes.

Bootstrap the bearer token into the new browser origin once:

```bash
tx9 open "$BOX"
```

Treat the printed `?_token=` URL as a secret. OAuth integrations should use:

```text
https://<node>.<tailnet>.ts.net/api/oauth/callback
```

Do not disable TLS verification; Tailscale Serve supplies a trusted
certificate.

## Run Hermes independently of tmux

`hermes gateway setup` configures Discord, Telegram, or another platform, but
`hermes gateway run` is a foreground process. If it is launched directly in a
tmux pane, closing that pane or its shell takes the gateway offline.

Configure Hermes inside the box, then let TX9 own the long-running process:

```bash
tx9 enter "$BOX"
hermes gateway setup
# Leave any foreground gateway once setup is complete, then detach/exit.
```

From the TX9 host, explicitly pass the single-writer gate:

```bash
tx9 gateway enable "$BOX" --confirm-single-writer
tx9 gateway status "$BOX"
tx9 doctor "$BOX"
```

TX9 first stops any foreground gateway left by setup, then starts it without a
TTY; its reconcile loop restarts it after a crash. Docker's `unless-stopped`
policy restores the container after a host reboot. The confirmation flag means
no other machine is running the same messaging identity; never use it until the
previous gateway is stopped.

To stop the messaging gateway without stopping the whole box:

```bash
tx9 gateway disable "$BOX"
```

## Remove the HTTPS configuration

Return the box to TX9's default Docker-assigned HTTP port and remove its
persisted public URL/DNS overrides:

```bash
tx9 upgrade "$BOX" --clear-executor-config
tailscale serve --https=443 off
```

The Serve command disables the node's default HTTPS listener. If other
services share that listener, edit the Serve configuration instead of clearing
it wholesale. For a non-default HTTPS port, replace `443` with that port.

## More than one Executor on a host

Only one backend can own the root of the node's default HTTPS port. For another
box, use a second fixed host port and a second Serve HTTPS port, then include
that public port in Executor's web base URL:

```bash
BOX=second-bot
PORT=32771
HTTPS_PORT=8443

tx9 upgrade "$BOX" \
  --executor-web-base-url "https://$MAGICDNS:$HTTPS_PORT" \
  --executor-publish "127.0.0.1:$PORT" \
  --executor-dns "100.100.100.100,$UPSTREAM_DNS"

tailscale serve --bg --yes --https="$HTTPS_PORT" \
  "http://127.0.0.1:$PORT"
```

## Troubleshooting

### HTTPS works on the host but not in the container

Inspect the configured resolvers and test tailnet plus public names:

```bash
docker inspect "tx9-$BOX-executor" \
  --format '{{json .HostConfig.Dns}}'
docker exec "tx9-$BOX-executor" getent hosts "$MAGICDNS"
docker exec "tx9-$BOX-executor" getent hosts github.com
```

Use both `100.100.100.100` and a real upstream resolver. A loopback resolver
such as `127.0.0.53` belongs to the host network namespace and is not a usable
Docker DNS target.

### OAuth still advertises localhost or HTTP

Confirm the environment reached the running Executor process configuration:

```bash
docker inspect "tx9-$BOX-executor" \
  --format '{{range .Config.Env}}{{println .}}{{end}}' |
  grep '^EXECUTOR_WEB_BASE_URL='
```

If it is missing, rerun `tx9 upgrade` with the three Executor options above.

### The public URL fails after an upgrade

Check that the fixed port is still published and that Serve points to it:

```bash
docker port "tx9-$BOX-executor" 4788/tcp
tailscale serve status
```

Older TX9 versions used an automatically assigned port and did not persist
Executor proxy settings. Apply the configuration again with a TX9 version that
supports the Executor options.

## References

- [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)
- [Tailscale Docker parameters](https://tailscale.com/docs/features/containers/docker/docker-params)
- [Executor self-hosting and `EXECUTOR_WEB_BASE_URL`](https://executor.sh/docs/hosted/docker)
