#!/usr/bin/env bash
# install.sh against a fake release: SHA256SUMS and an archive served from
# files (file:// through curl, or http:// when INSTALL_TEST_HTTP=1, through
# python's http.server), in a temporary HOME. Each case prints `ok <case>`;
# the first failure prints `FAIL <case>: <why>` and exits 1.
#
# Usage: tests/install.test.sh   (from anywhere; needs bash, curl, tar, and
# sha256sum or shasum)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
installer=$here/../installers/install.sh
work=$(mktemp -d)
server=
cleanup() { [ -n "$server" ] && kill "$server" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT

case "$(uname -s)" in Linux) os=linux ;; Darwin) os=macos ;; *) echo "SKIP install.test.sh: not linux or macos"; exit 0 ;; esac
case "$(uname -m)" in x86_64 | amd64) arch=x86_64 ;; *) arch=arm64 ;; esac
if [ "$os" = macos ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then arch=arm64; fi
sum() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

fail() { echo "FAIL $1: $2" >&2; exit 1; }

# The fake release: demo's archive for here, one for another platform, and a
# debug file, as the release workflow lays them out.
rel=$work/release
mkdir -p "$rel" "$work/stage"
printf '#!/bin/sh\necho "demo $*"\n' > "$work/stage/demo"
chmod 0755 "$work/stage/demo"
archive="demo-0.1.0+abc1234-$os-$arch.tar.gz"
tar -czf "$rel/$archive" -C "$work/stage" demo
other="demo-0.1.0+abc1234-plan9-mips.tar.gz"
cp "$rel/$archive" "$rel/$other"
echo debug > "$rel/demo-0.1.0+abc1234-$os-$arch.debug"
(cd "$rel" && for f in demo-*; do echo "$(sum "$f")  $f"; done) > "$rel/SHA256SUMS"

if [ "${INSTALL_TEST_HTTP:-}" = 1 ]; then
    port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
    python3 -m http.server "$port" --bind 127.0.0.1 --directory "$rel" >/dev/null 2>&1 &
    server=$!
    for _ in $(seq 50); do curl -fsS "http://127.0.0.1:$port/SHA256SUMS" >/dev/null 2>&1 && break; sleep 0.1; done
    url="http://127.0.0.1:$port"
else
    url="file://$rel"
fi

run() { # <home> [args...]: the installer's output in $out, its exit in $rc
    local home=$1; shift
    rc=0
    out=$(HOME=$home INSTALL_BASE_URL=$url sh "$installer" "$@" 2>&1) || rc=$?
}

# A clean install, then an idempotent second one, with a wrapper variable.
home=$work/home1
mkdir -p "$home"
run "$home" --repo ctxloom/demo --bin demo
[ "$rc" -eq 0 ] || fail install "exit $rc: $out"
[ -x "$home/.local/lib/demo/demo" ] || fail install "no executable ~/.local/lib/demo/demo"
[ -x "$home/.local/bin/demo" ] || fail install "no executable wrapper"
[ "$(HOME=$home "$home/.local/bin/demo" hi)" = "demo hi" ] || fail install "the wrapper does not run the binary"
echo "ok install"

# shellcheck disable=SC2016 # expanded by the wrapper, not here
INSTALL_WRAPPER_ENV='DEMO_HOME=$HOME/.demo-rs' run "$home" --repo ctxloom/demo --bin demo
[ "$rc" -eq 0 ] || fail reinstall "exit $rc: $out"
# shellcheck disable=SC2016
grep -qx 'export DEMO_HOME="$HOME/.demo-rs"' "$home/.local/bin/demo" || fail reinstall "the wrapper lacks its variable: $(cat "$home/.local/bin/demo")"
[ "$(ls "$home/.local/lib/demo")" = demo ] || fail reinstall "left files beside the binary: $(ls "$home/.local/lib/demo")"
echo "ok reinstall with a wrapper variable"

# A tampered archive is refused and installs nothing.
home=$work/home2
mkdir -p "$home"
cp "$rel/$archive" "$work/good"
echo tampered >> "$rel/$archive"
run "$home" --repo ctxloom/demo --bin demo
cp "$work/good" "$rel/$archive"
[ "$rc" -ne 0 ] || fail tampered "a tampered archive installed: $out"
grep -q "sha256 is" <<< "$out" || fail tampered "no checksum message: $out"
[ ! -e "$home/.local/lib/demo/demo" ] || fail tampered "installed the tampered binary"
echo "ok tampered archive refused"

# With neither sha256sum nor shasum it refuses rather than skips.
bare=$work/bare
mkdir -p "$bare"
for tool in sh awk uname mktemp curl tar mkdir cp chmod mv rm grep sed cat printf sysctl xattr; do
    p=$(command -v "$tool" 2>/dev/null) && [ -n "$p" ] && [ "${p#/}" != "$p" ] && ln -sf "$p" "$bare/$tool"
done
home=$work/home3
mkdir -p "$home"
rc=0
out=$(PATH=$bare HOME=$home INSTALL_BASE_URL=$url "$bare/sh" "$installer" --repo ctxloom/demo --bin demo 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail no-sha-tool "installed without a checksum tool: $out"
grep -q "neither sha256sum nor shasum" <<< "$out" || fail no-sha-tool "no refusal message: $out"
[ ! -e "$home/.local/lib/demo" ] || fail no-sha-tool "installed something"
echo "ok no checksum tool refused"

# No archive for the binary: refused.
run "$work/home4" --repo ctxloom/demo --bin nothing
{ [ "$rc" -ne 0 ] && grep -q "lists 0 archives" <<< "$out"; } || fail no-archive "exit $rc: $out"
echo "ok no archive refused"

# No repository or binary named: refused.
rc=0
out=$(HOME=$work/home5 sh "$installer" 2>&1) || rc=$?
{ [ "$rc" -ne 0 ] && grep -q "no repository" <<< "$out"; } || fail no-repo "exit $rc: $out"
echo "ok no repository refused"
