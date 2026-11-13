# ctxloom/ci

The shared CI of the ctxloom family (ctxloom, taskloom, ctxloom-lib), ruled
by the owner on 2026-11-12: composite actions for setup, so each repository's
job names and gate list stay its own; reusable workflows only where the
pipeline is the same everywhere (binaries, release); the installers a release
attaches. Licence: `Apache-2.0 OR BSD-3-Clause` (both files), as
angzarr-platform's crates.

## Layout

- `.github/actions/<name>/action.yml`: composite actions. setup-rust,
  setup-protoc, setup-versionator, setup-ltk, gate-logs, package-binary.
- `.github/workflows/binaries.yml`, `release.yml`: reusable (`workflow_call`).
- `.github/workflows/ci.yml`: this repository's own CI (actionlint,
  shellcheck, the pin check, and self-tests that run the actions from `./`
  and the installers against fixtures on linux, macOS and Windows).
- `installers/install.sh`, `installers/install.ps1`: parameterized by repo
  and binary (flags or `INSTALL_*`); the release workflow bakes the caller's
  defaults into the `DEFAULT_*` / `$Default*` lines. Never edit those lines'
  shape without the release workflow's sed.
- `tests/`: `install.test.sh` (file:// or, with `INSTALL_TEST_HTTP=1`,
  http://) and `install.test.ps1` (http://; it writes HKCU, runner only).

## Pinning rule

Everything is pinned. Every `uses:` of another repository names a FULL
commit, its release in a comment (`@<40 hex> # v7.0.1`); the lint job refuses
anything else. Every tool is pinned to a version (install-action's
`tool@x.y.z`), and every download to a sha256 written in the action
(protoc's and versionator's tables; versionator's is also matched against
its release's checksums.txt). Adding a version or a platform means adding its
checksum, computed from the release's file.

No secret but `GITHUB_TOKEN`. `contents: read` everywhere; `contents: write`
on release.yml's `release` job alone (the caller's calling job must grant it).

## Self-references

A reusable workflow's `uses: ./...` would resolve against the CALLER's
checkout, so binaries.yml names this repository's actions as
`ctxloom/ci/.github/actions/<name>@<sha>`, at an EARLIER commit of this
repository (a commit cannot name itself). So a change to an action reaches
the reusable workflows in two commits: the action, then a commit bumping the
workflows' pins to it. release.yml takes `ci-ref` (the caller's pin of this
repository) to check out the installers it attaches.

## How callers pin and bump

A caller pins every action and workflow of this repository at ONE commit of
`main`, with the date in the comment (`@<sha> # main 2026-11-12`); there are
no tags yet (agents cut none; the owner may). To bump: land the change here
(its CI green), then in the caller replace the sha everywhere at once
(`grep -rl ctxloom/ci@ .github | xargs sed -i 's/<old>/<new>/'`, plus
release.yml's `ci-ref`), and let the caller's CI prove it.

## Working rules

- Lint before pushing: `actionlint` (1.7.12) and `shellcheck` over the
  scripts; run `tests/install.test.sh` locally.
- A composite action's steps that must run after a failure say
  `if: always()` themselves; the caller decides with its own `if:`.
- Keep the actions generic: anything one repository alone needs is its input
  or its own recipe (package-binary runs the caller's `just` recipes).
