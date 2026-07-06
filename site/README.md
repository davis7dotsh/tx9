# site/ — tx9.davis7.sh

Cloudflare Worker serving tx9's public face (docs/tx9-cli-design.md
decision 10): the homepage, the `curl | sh` installer, and release binary
downloads out of an R2 bucket.

## URL surface

| Route | Serves |
|---|---|
| `/` | `public/index.html` homepage |
| `/install` (and `/install.sh`) | `scripts/install.sh`, imported at build time — no copy step, can't drift |
| `/releases/latest` | current version as bare text (e.g. `0.1.0`) |
| `/releases/latest/<asset>` | 302 to the versioned path |
| `/releases/<version>/<asset>` | binary / `checksums.txt` from R2 |

## R2 bucket layout (`tx9-releases`)

```
latest.txt                    "0.1.0\n" — flipped last during publish
0.1.0/tx9_linux_amd64
0.1.0/tx9_linux_arm64
0.1.0/tx9_darwin_amd64
0.1.0/tx9_darwin_arm64
0.1.0/checksums.txt
```

`.github/workflows/release.yml` writes this on every `v*` tag push, after
attaching the same files to the GitHub release (which `tx9 upgrade`
self-update consumes).

## One-time setup

1. `npx wrangler r2 bucket create tx9-releases`
2. Add repo secrets `CLOUDFLARE_API_TOKEN` (Workers R2 Storage: edit) and
   `CLOUDFLARE_ACCOUNT_ID` for the release workflow.
3. With the `davis7.sh` zone on Cloudflare, uncomment the `routes` block in
   `wrangler.jsonc` to bind `tx9.davis7.sh` as a custom domain.

## Develop / deploy

```bash
cd site
npm install
npm run check    # wrangler types + tsc --noEmit
npm run dev      # local worker with a local R2 stub
npm run deploy
```

To exercise the release routes locally, seed the dev R2 stub:

```bash
printf '0.0.1\n' > /tmp/latest.txt
npx wrangler r2 object put tx9-releases/latest.txt --file /tmp/latest.txt --local
```
