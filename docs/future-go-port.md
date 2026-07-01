# Note: considered and deferred a Go rewrite (2026-06-30)

While auditing the bash scripts on `audit/2026-06-30-box-new-fixes`, we
evaluated whether to rewrite `./box`, `guest/hb`, `guest/hermes-state`, and
`provision/provision.sh` in Go for easier testing and maintenance. Conclusion:
**not now, and not the guest-side scripts.** Recorded here so the reasoning
doesn't have to be re-derived next time this comes up.

## Recommendation if this is revisited

A **partial rewrite of `./box` only** (the host-side CLI) is the one variant
worth considering later. `guest/hb`, `guest/hermes-state`, and
`provision/provision.sh` should stay in bash/Python.

## Why not the guest-side scripts

- `guest/hb` and `guest/hermes-state` run *inside* the guest VM;
  `provision/provision.sh` runs during early guest bootstrap, before most
  tooling exists. Porting them means shipping a Go toolchain (or
  cross-compiled binaries) into the guest image and solving a chicken-and-egg
  bootstrap problem for provisioning itself.
- Their tests are inherently integration-style regardless of language (they
  exercise real state transitions against a real or faked guest); Go's type
  system wouldn't meaningfully change that.

## Why `./box` is at least plausible

- It runs on a normal host OS (macOS/Linux) with a normal toolchain — trivial
  Go target, no cross-compilation or bundling problem.
- A large fraction of its size is shelling out to `smolvm`/`gpg`/`curl`/`jq`/
  `tar` — Go doesn't remove that shell-out surface, but it would give the
  surrounding logic (arg parsing, port/lock state, error propagation) real
  types and table-driven unit tests instead of bash integration tests.

## Why we're not doing it now

- This branch just finished a security/reliability audit that fixed ~20 real
  bugs in this exact code (see `docs/audit-2026-06-30-fixes.md`), several
  around locking and races. A rewrite reintroduces that entire risk class in
  new code before it's had time to prove itself in production.
- Rough cost: a `box`-only port is ~1 month to reach the confidence level the
  current bash already has; a full rewrite (including guest scripts) is
  3-4 months once retesting and migration are accounted for, for
  comparatively little extra benefit.

If a Go rewrite of `./box` is picked up later, treat it as its own dedicated
project with its own review cycle — not something to fold into an unrelated
feature or fix branch.
