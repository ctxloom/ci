#!/bin/sh
# Install a ctxloom-family binary from its GitHub release (Linux and macOS).
#
#   curl -fsSL https://github.com/<repo>/releases/latest/download/install.sh | sh
#   sh install.sh [--repo <owner/name>] [--bin <name>] [--version <tag>|latest]
#
# It picks the release's archive for this OS and arch
# (`<bin>-<stamp>-<os>-<arch>.tar.gz`, os linux|macos, arch x86_64|arm64)
# from the release's SHA256SUMS, downloads it, and verifies it against that
# file with sha256sum, else `shasum -a 256`; with neither it REFUSES, never
# skips. It installs the binary as ~/.local/lib/<bin>/<bin> (beside it, then
# renamed over it, so a running copy keeps its file) and a wrapper
# ~/.local/bin/<bin> that execs it. On macOS it clears com.apple.quarantine
# from the archive and the installed files (an absent attribute is fine).
#
# Environment (each overrides the default; the flags override these):
#   INSTALL_REPO, INSTALL_BIN, INSTALL_VERSION   as the flags
#   INSTALL_BASE_URL     where SHA256SUMS and the archives are (default: the
#                        release's download URL on github.com)
#   INSTALL_WRAPPER_ENV  space-separated NAME=VALUE pairs the wrapper exports
#                        (VALUE is expanded when the wrapper runs, so
#                        `X=$HOME/.x` names the runner's home)
# The release workflow of github.com/ctxloom/ci sets the DEFAULT_* lines below
# for the release it attaches this script to.
#
# SPDX-License-Identifier: Apache-2.0 OR BSD-3-Clause
set -eu

DEFAULT_REPO=''
DEFAULT_BIN=''
DEFAULT_VERSION='latest'
DEFAULT_WRAPPER_ENV=''

say() { printf '%s\n' "install: $*"; }
fail() { printf '%s\n' "install: $*" >&2; exit 1; }

repo=${INSTALL_REPO:-$DEFAULT_REPO}
bin=${INSTALL_BIN:-$DEFAULT_BIN}
version=${INSTALL_VERSION:-$DEFAULT_VERSION}
wrapper_env=${INSTALL_WRAPPER_ENV:-$DEFAULT_WRAPPER_ENV}
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) [ $# -ge 2 ] || fail "--repo needs a value"; repo=$2; shift 2 ;;
        --bin) [ $# -ge 2 ] || fail "--bin needs a value"; bin=$2; shift 2 ;;
        --version) [ $# -ge 2 ] || fail "--version needs a value"; version=$2; shift 2 ;;
        -h | --help) sed -n '2,/^# SPDX/p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) fail "unknown argument '$1' (--repo, --bin, --version)" ;;
    esac
done
[ -n "$repo" ] || fail "no repository: give --repo <owner/name>"
[ -n "$bin" ] || fail "no binary name: give --bin <name>"
case "$bin" in
    *[!A-Za-z0-9._-]* | .*) fail "'$bin' is not a binary name" ;;
esac
[ -n "${HOME:-}" ] || fail "HOME is not set"

case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=macos ;;
    MINGW* | MSYS* | CYGWIN*) fail "on Windows run install.ps1 in PowerShell" ;;
    *) fail "no release for $(uname -s)" ;;
esac
case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    arm64 | aarch64) arch=arm64 ;;
    *) fail "no release for $(uname -m)" ;;
esac
# A shell under Rosetta says x86_64 on an arm64 Mac: install the native one.
if [ "$os" = macos ] && [ "$arch" = x86_64 ] &&
    [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
    arch=arm64
fi

if [ -n "${INSTALL_BASE_URL:-}" ]; then
    base=${INSTALL_BASE_URL%/}
elif [ "$version" = latest ]; then
    base="https://github.com/$repo/releases/latest/download"
else
    base="https://github.com/$repo/releases/download/$version"
fi

if command -v sha256sum >/dev/null 2>&1; then
    digest() { sha256sum "$1" | awk '{ print $1 }'; }
elif command -v shasum >/dev/null 2>&1; then
    digest() { shasum -a 256 "$1" | awk '{ print $1 }'; }
else
    fail "neither sha256sum nor shasum is installed: the download cannot be verified, so nothing is installed"
fi
if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -q -O "$2" "$1"; }
else
    fail "neither curl nor wget is installed"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/install-$bin.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM HUP

fetch "$base/SHA256SUMS" "$work/SHA256SUMS" || fail "could not download $base/SHA256SUMS"
# `<64 hex>  <file>` (or `*<file>`, binary mode), the archive for here.
matches=$(awk -v bin="$bin" -v tail="-$os-$arch.tar.gz" '
    { f = $2; sub(/^\*/, "", f) }
    length($1) == 64 && index(f, bin "-") == 1 && length(f) > length(tail) &&
        substr(f, length(f) - length(tail) + 1) == tail { print $1, f }' "$work/SHA256SUMS")
count=$(printf '%s' "$matches" | grep -c . || true)
[ "$count" -eq 1 ] || fail "SHA256SUMS lists $count archives for $bin on $os-$arch, not one"
want=${matches%% *}
archive=${matches#* }
case "$archive" in */* | *..*) fail "SHA256SUMS names an unsafe file '$archive'" ;; esac

say "downloading $archive"
fetch "$base/$archive" "$work/$archive" || fail "could not download $base/$archive"
got=$(digest "$work/$archive")
[ "$got" = "$want" ] || fail "$archive's sha256 is $got, but SHA256SUMS says $want: nothing is installed"
say "verified $archive (sha256 $got)"

unquarantine() {
    [ "$os" = macos ] || return 0
    command -v xattr >/dev/null 2>&1 || return 0
    xattr -dr com.apple.quarantine "$@" 2>/dev/null || true
}
unquarantine "$work/$archive"

mkdir "$work/x"
tar -xzf "$work/$archive" -C "$work/x"
[ -f "$work/x/$bin" ] || fail "$archive holds no $bin"
[ -x "$work/x/$bin" ] || fail "$archive's $bin is not executable"

lib="$HOME/.local/lib/$bin"
program="$lib/$bin"
wrapper="$HOME/.local/bin/$bin"
mkdir -p "$lib" "$HOME/.local/bin"
cp "$work/x/$bin" "$program.new"
chmod 0755 "$program.new"
mv -f "$program.new" "$program"
say "installed $program"

{
    echo '#!/bin/sh'
    for pair in $wrapper_env; do
        name=${pair%%=*}
        value=${pair#*=}
        case "$name" in "" | [0-9]* | *[!A-Za-z0-9_]*) fail "'$name' is not a variable name" ;; esac
        [ "$name" != "$pair" ] || fail "'$pair' is not NAME=VALUE"
        # shellcheck disable=SC1003 # the pattern is a backslash
        case "$value" in *'"'* | *'`'* | *'\'*) fail "$name's value may not hold a quote, backquote or backslash" ;; esac
        printf 'export %s="%s"\n' "$name" "$value"
    done
    # shellcheck disable=SC2016 # the wrapper expands them when it runs
    printf 'exec "$HOME/.local/lib/%s/%s" "$@"\n' "$bin" "$bin"
} > "$wrapper.new"
chmod 0755 "$wrapper.new"
mv -f "$wrapper.new" "$wrapper"
say "wrote $wrapper"
unquarantine "$program" "$wrapper"

case ":${PATH:-}:" in
    *":$HOME/.local/bin:"*) ;;
    *) say "note: $HOME/.local/bin is not on PATH; add it to your shell's profile" ;;
esac
say "run 'hash -r' (bash) or 'rehash' (zsh) in shells that ran $bin before"
