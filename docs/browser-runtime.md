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

Presence or `--version` is not enough. The probe launches chrome with
`--headless=new --dump-dom` against the local fixture and requires the
marker `TX9_BROWSER_FIXTURE_OK`. `hb doctor` fails when the result is not
`ok`. HTTPS against example.com runs only when `TX9_BROWSER_HTTPS_SMOKE=1`.

## Sandbox

The image does not set the SUID bit on `chrome_sandbox`. When user
namespaces are restricted (the process is root,
`unprivileged_userns_clone=0`, or
`apparmor_restrict_unprivileged_userns=1`), the health probe may add
`--no-sandbox --disable-dev-shm-usage`. Hermes may inject the same flags.
TX9 does not export `AGENT_BROWSER_ARGS` or
`AGENT_BROWSER_EXECUTABLE_PATH`.

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
