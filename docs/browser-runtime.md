# Image-owned Chromium runtime

TX9 installs Chrome for Testing and agent-browser under
`/opt/hermes-box/browser` during image build. Durable `/data` is not the
install location. Hermes still runs with `--skip-browser`. TX9 seeds a local
chrome engine only when no browser backend is already selected.

## Pins

Pins live in `box.env` and were measured on 2026-09-10.

- agent-browser 0.26.0
- Chrome for Testing 153.0.8010.36

`provision/install-browser.sh` selects linux-x64 or linux-arm64 from
`uname -m` and checks the matching sha256. An unknown machine type fails
the build. An amd64 artifact is never treated as arm64.

`install-browser.sh` skips the download when `manifest.json` matches the
current pins and both binaries exist. OS libraries come from Chrome's own
`deb.deps` via `apt-get satisfy`, plus `unzip` and `libnss3-tools`. The
image does not run `npm install -g`, `vp install -g agent-browser`, or
`agent-browser install --with-deps`.

## Health

`tx9-browser health` returns the first failure.

- `ok`
- `cli_missing`
- `browser_missing`
- `libs_missing`
- `launch_failed`
- `navigate_failed`

Presence or `--version` is not enough. The probe runs image
`agent-browser --executable-path` against the local fixture and requires
the marker `TX9_BROWSER_FIXTURE_OK` in the accessibility snapshot.
`--dump-dom` is not the health signal. Chrome 153 never finishes that
command in Docker even when CDP is already up. `hb doctor` fails when the
result is not `ok`. HTTPS against example.com runs only when
`TX9_BROWSER_HTTPS_SMOKE=1`.

`agent-browser` does not treat `$PATH/chrome` as a system install. The
image links `/usr/bin/google-chrome` and `/usr/bin/google-chrome-stable`
to `/opt/hermes-box/bin/chrome` so a plain `agent-browser open` finds it.

## Sandbox

The image does not set the SUID bit on `chrome_sandbox`. Hermes and
agent-browser may add `--no-sandbox --disable-dev-shm-usage` when user
namespaces cannot create a sandbox. TX9 does not export
`AGENT_BROWSER_ARGS` or `AGENT_BROWSER_EXECUTABLE_PATH`.

`~/.local` browser binaries stay. `hb doctor` may note when PATH hides
the image `agent-browser`.

## Upgrade and rollback

To upgrade, change the pins in `box.env`, rebuild the CLI with `make tx9`,
and rebuild the image. The CLI embeds the build context, so editing
`box.env` alone does not change `tx9 create`. To roll back, restore the
previous pins and rebuild the same way.

## What this does not fix

Repairing a live container's browser install is not product-ready. Hermes
`key_cmd` auth is out of scope.
