# Dependency and distribution audit, 2026-08-27

This audit updates the CLI's compiled dependencies and the site's locked tooling.
It does not rebuild images, upgrade running boxes, or deploy the Worker.

## Versions and sources

Versions were checked against the Go module proxy, npm registry, and upstream
release APIs on August 27, 2026. The lockfiles record the selected transitive
dependencies and integrity hashes.

| Component | Before | Selected | Reason |
|---|---|---|---|
| Go | minimum 1.26; audit host 1.26.5 | 1.26.7 | Current supported patch of the existing minor; avoids an unrelated 1.27 migration |
| Docker client module | 28.5.2 | 28.5.2 | Latest release under the existing module path; migration to modular Moby APIs is separate work |
| docker/go-connections | 0.7.0 | 0.8.1 | Current compatible release |
| x/sys / x/term | 0.46.0 / 0.44.0 | 0.47.0 / 0.45.0 | Current compatible releases |
| OpenTelemetry / otelhttp | 1.44.0 / 0.69.0 | 1.46.0 / 0.71.0 | Refresh the Docker client's instrumentation dependencies |
| TypeScript | 5.9.3 | 7.0.2 | Current compiler; existing Worker type check passes unchanged |
| Wrangler | lockfile 4.107.0 | 4.127.0 | Current release, including fixes in development dependencies |
| Prettier / Oxlint | absent | 3.9.6 / 1.80.0 | Reproducible formatting and lint checks for site source and tests |
| checkout / setup-go / setup-node | floating action tags | 7.0.1 / 7.0.0 / 7.0.0, commit-pinned | Auditable action content |
| action-gh-release | floating action tag | 3.0.2, commit-pinned | Auditable release action content |
| ShellCheck | 0.11.0 without archive verification | 0.11.0 with SHA-256 verification | Verify the downloaded executable before installation |

Primary references: [Go releases](https://go.dev/dl/),
[Wrangler releases](https://github.com/cloudflare/workers-sdk/releases),
[TypeScript releases](https://github.com/microsoft/TypeScript/releases),
[checkout 7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1),
[setup-go 7.0.0](https://github.com/actions/setup-go/releases/tag/v7.0.0),
[setup-node 7.0.0](https://github.com/actions/setup-node/releases/tag/v7.0.0),
[action-gh-release 3.0.2](https://github.com/softprops/action-gh-release/releases/tag/v3.0.2),
and [ShellCheck 0.11.0](https://github.com/koalaman/shellcheck/releases/tag/v0.11.0).

`go list -m -u all` still reports newer versions for ten modules retained only
in dependency manifests: containerd/typeurl, creack/pty, moby/sys/sequential,
rogpeppe/go-internal, logrus, x/mod, x/tools, genproto/googleapis/api,
genproto/googleapis/rpc, and grpc. None occurs in the modules used by
`go list -deps -test ./...`. Adding unused direct constraints solely to change
these graph entries would not update code compiled into tx9 or its tests.

## Advisory results

- The original npm lockfile had four high-severity findings through Wrangler,
  Miniflare, Sharp, and Undici. These are development tooling, not Worker runtime
  dependencies. The refreshed lockfile has zero findings from `npm audit`.
  Relevant advisories include
  [Sharp/libvips](https://github.com/advisories/GHSA-f88m-g3jw-g9cj) and
  [Undici cache leakage](https://github.com/advisories/GHSA-4cwx-7wf7-3272).
- The Go 1.26.5 baseline had reachable standard-library advisories
  [GO-2026-5026](https://pkg.go.dev/vuln/GO-2026-5026),
  [GO-2026-5972](https://pkg.go.dev/vuln/GO-2026-5972),
  [GO-2026-6090](https://pkg.go.dev/vuln/GO-2026-6090), and
  [GO-2026-6218](https://pkg.go.dev/vuln/GO-2026-6218). The scan after moving to
  1.26.7 reports no standard-library findings.
- Govulncheck still reports Docker module advisories
  [GO-2026-4883](https://pkg.go.dev/vuln/GO-2026-4883),
  [GO-2026-4887](https://pkg.go.dev/vuln/GO-2026-4887),
  [GO-2026-5617](https://pkg.go.dev/vuln/GO-2026-5617),
  [GO-2026-5668](https://pkg.go.dev/vuln/GO-2026-5668), and
  [GO-2026-5746](https://pkg.go.dev/vuln/GO-2026-5746). Their affected behavior is
  in the Docker daemon: plugin authorization and container archive handling.
  tx9 uses the client package and does not embed a daemon. The first two
  advisories broadly mark the module's symbols, so the scan labels client
  calls as reachable too. This is not a clean scan or evidence that a host's
  Docker daemon is patched. Host Docker updates remain an operator task.

## Provisioned tools

Provisioning still follows upstream channels: Claude's stable native installer,
Codex's latest native installer, Node LTS through Vite+, and fresh Executor,
Hermes, uv, and Vite+ installs. Registry/release checks found Executor 1.6.0,
Hermes 2026.8.27, uv 0.12.6, and Vite+ 0.3.0. These are observations, not new
image pins. Existing Executor and Hermes installs are intentionally retained
by the provisioning script; cached Docker layers also retain installed tools.

The base image remains Ubuntu 24.04, selected by `docker/Dockerfile`.
`BASE_IMAGE` in `box.env` is only an informational label. Obsolete exposure and
host-port range variables were removed because no code reads them.

Floating installers and a mutable base-image tag trade reproducibility for
upstream updates. A fully pinned image needs a separate release/update policy
and an image build plus runtime validation. This audit does not establish the
versions or vulnerability status of packages inside existing images or boxes.

## Validation and reproduction

Dependency changes used package-manager commands, followed by tidy/lockfile
generation. The relevant commands were:

```sh
go get go@1.26.7
go get -u ./...
go get -u all
go get go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp@latest
go mod tidy
go list -m -u -json all
go list -deps -test -buildvcs=false -f '{{with .Module}}{{.Path}}{{end}}' ./...
go run golang.org/x/vuln/cmd/govulncheck@v1.7.0 -json ./...
make format
make check
go test -race -buildvcs=false ./...
```

The formatting, lint, shell regressions, Go vet, Go tests, and race checks pass.
`make check` no longer repeats a separate `go build`; `go test ./...` already
compiles every package, including packages without tests.

From `site/`:

```sh
npm install --save-dev --save-exact typescript@7.0.2 wrangler@4.127.0 prettier@3.9.6 oxlint@1.80.0
npm install --package-lock-only --ignore-scripts
npm ci --ignore-scripts
npm run check
npm run format:check
npm run lint
npm test
npm audit --audit-level=high
npm exec --yes --package=node@22.18.0 -- node --import ./tests/text-modules.mjs --test tests/worker.test.mjs
```

All site checks pass on Linux x86-64 after a fresh install with lifecycle scripts disabled,
including the native Oxlint and TypeScript binaries and Wrangler's type
generation. All eight Worker tests also pass on the declared minimum Node
22.18.0. CI uses Node 24 LTS.

Actionlint 1.7.12 passes both workflow files with only the two existing
Depot extensions excluded: the `depot-ubuntu-latest` runner label and
`concurrency.queue`:

```sh
go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12 \
  -ignore 'label "depot-ubuntu-latest" is unknown' \
  -ignore 'unexpected key "queue" for "concurrency" section' \
  .depot/workflows/check.yml .depot/workflows/release.yml
```

Hosted CI, image builds, cross-compilation, and Worker deployment were not run
during this audit.
