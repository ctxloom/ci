# ctxloom/ci

Shared CI for the ctxloom family (ctxloom, taskloom, ctxloom-lib): composite
actions for a job's setup, reusable workflows for binaries and releases, and
the installers a release attaches.

| Path | What |
|---|---|
| `.github/actions/setup-rust` | the caller's rust-toolchain.toml, extra targets, pinned tools (taiki-e/install-action), rust-cache saved on main only |
| `.github/actions/setup-protoc` | protoc by version, checked against a pinned sha256 per OS and arch |
| `.github/actions/setup-versionator` | versionator's release binary, checked against a pinned sha256 and its checksums.txt (no Go) |
| `.github/actions/setup-ltk` | ltk go-installed at a pinned commit and cached; Go only on a cache miss |
| `.github/actions/gate-logs` | print and upload `target/logs` (call with `if: failure()`) |
| `.github/actions/package-binary` | the caller's `just release-binary` / `release-package`, archived (tar.gz on unix, zip on Windows) and uploaded as-is |
| `.github/workflows/binaries.yml` | reusable: one package-binary job per target (linux-x86_64, windows-x86_64, macos-arm64, macos-x86_64 cross-built on macos-15) |
| `.github/workflows/release.yml` | reusable: installers, SHA256SUMS, and on a `v*` tag matching VERSION, `gh release create` |
| `installers/install.sh` | Linux and macOS: checksum-verified (refuses with no checker), `~/.local/lib/<bin>/<bin>` plus a `~/.local/bin/<bin>` wrapper, quarantine cleared |
| `installers/install.ps1` | Windows: Get-FileHash-verified, `%LOCALAPPDATA%\Programs\<bin>`, HKCU Path, Unblock-File |

Use it pinned by full commit, its release or date in the comment:

```yaml
- uses: ctxloom/ci/.github/actions/setup-rust@<40-hex sha> # main 2026-11-12
  with:
    tools: just@1.40.0,cargo-nextest@0.9.146
```

```yaml
jobs:
  binaries:
    uses: ctxloom/ci/.github/workflows/binaries.yml@<sha> # main 2026-11-12
    with:
      bin: ctxloom
```

Install a release (once one is published):

```sh
curl -fsSL https://github.com/ctxloom/ctxloom/releases/latest/download/install.sh | sh
```

```powershell
irm https://github.com/ctxloom/ctxloom/releases/latest/download/install.ps1 | iex
```

Licensed under either of Apache-2.0 (`LICENSE-APACHE`) or BSD-3-Clause
(`LICENSE-BSD`), at your option.
