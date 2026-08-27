# site/ — tx9.col-agents.com

Cloudflare Worker serving tx9's public face (docs/tx9-cli-design.md
decision 10): the homepage, the `curl | sh` installer, and release binary
downloads out of an R2 bucket.

## URL surface

| Route | Serves |
|---|---|
| `/` | `public/index.html` homepage |
| `/install` (and `/install.sh`) | `scripts/install.sh`, imported at build time via the `src/install.txt` symlink — no copy step, can't drift. (The `.txt` alias is load-bearing: Cloudflare's API WAF rejects worker uploads containing a `*.sh` module with shell content.) |
| `/releases/latest` | current version as bare text (e.g. `0.1.0`) |
| `/releases/latest/<asset>` | 302 to the versioned path |
| `/releases/<version>/<asset>` | binary / `checksums.txt` from R2 |

## R2 bucket layout (`tx9-releases`)

```text
latest.txt                    "0.1.0\n" — flipped last during publish
0.1.0/tx9_linux_amd64
0.1.0/tx9_linux_arm64
0.1.0/tx9_darwin_amd64
0.1.0/tx9_darwin_arm64
0.1.0/checksums.txt
```

`.depot/workflows/release.yml` writes this on every `vX.Y.Z` tag push, after
attaching the same files to the GitHub release. The installer and
`tx9 upgrade` consume the public R2 routes, not the private GitHub release.

## One-time setup

1. `npx wrangler r2 bucket create tx9-releases`
2. Add Depot CI secrets for the release workflow (deploys run on Depot;
   these are `depot ci secrets`, not GitHub repo secrets):
   `CLOUDFLARE_API_TOKEN` (Workers R2 Storage: edit) and
   `CLOUDFLARE_ACCOUNT_ID`.
3. The `routes` block in `wrangler.jsonc` binds `tx9.col-agents.com`
   (interim hostname on the col-agents.com Cloudflare zone; swap the
   pattern when tx9 gets its own domain).

## Validate

Use Node.js 22.18 or newer. The tests load the actual Worker through Node's
TypeScript support and use an in-memory R2 stub; they do not start a server,
build a bundle, or contact Cloudflare.

```bash
cd site
npm ci --ignore-scripts
npm run check    # wrangler types + tsc --noEmit
npm run format:check
npm run lint
npm test
npm audit --audit-level=high
```

Run `npm run format` to apply formatting. CI uses the same locked tooling
for checks and release uploads, without package install scripts.

## Develop / deploy

```bash
npm run dev      # local worker with a local R2 stub
npm run deploy
```

To exercise the release routes locally, seed the dev R2 stub:

```bash
printf '0.0.1\n' > /tmp/latest.txt
npx wrangler r2 object put tx9-releases/latest.txt --file /tmp/latest.txt --local
```
