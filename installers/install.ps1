# Install a ctxloom-family binary from its GitHub release (Windows).
#
#   irm https://github.com/<repo>/releases/latest/download/install.ps1 | iex
#   .\install.ps1 [-Repo <owner/name>] [-Bin <name>] [-Version <tag>|latest] [-BaseUrl <url>]
#
# It picks the release's archive for Windows x86_64
# (`<bin>-<stamp>-windows-x86_64.zip`) from the release's SHA256SUMS,
# downloads it, and verifies it with Get-FileHash against that file, refusing
# on a mismatch. It installs `<bin>.exe` in %LOCALAPPDATA%\Programs\<bin> (the
# old one renamed aside first, so a running copy keeps its file), clears the
# Mark-of-the-Web from the archive and the installed exe (Unblock-File), and
# adds the directory to the user's Path (HKCU\Environment), once.
#
# Environment (the parameters override these): INSTALL_REPO, INSTALL_BIN,
# INSTALL_VERSION, INSTALL_BASE_URL (where SHA256SUMS and the archives are;
# default: the release's download URL on github.com). The release workflow of
# github.com/ctxloom/ci sets the $Default* lines below for the release it
# attaches this script to.
#
# SPDX-License-Identifier: Apache-2.0 OR BSD-3-Clause
param(
    [string]$Repo = '',
    [string]$Bin = '',
    [string]$Version = '',
    [string]$BaseUrl = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$DefaultRepo = ''
$DefaultBin = ''
$DefaultVersion = 'latest'

function Say([string]$Text) { Write-Host "install: $Text" }
# A throw, not `exit`: under `irm | iex` an exit would close the user's shell.
function Fail([string]$Text) { throw "install: $Text" }
function Pick([string]$Given, [string]$Variable, [string]$Default) {
    if ($Given) { return $Given }
    $fromEnv = [Environment]::GetEnvironmentVariable($Variable)
    if ($fromEnv) { return $fromEnv }
    return $Default
}

$Repo = Pick $Repo 'INSTALL_REPO' $DefaultRepo
$Bin = Pick $Bin 'INSTALL_BIN' $DefaultBin
$Version = Pick $Version 'INSTALL_VERSION' $DefaultVersion
$BaseUrl = Pick $BaseUrl 'INSTALL_BASE_URL' ''
if (-not $Repo) { Fail 'no repository: give -Repo <owner/name>' }
if (-not $Bin) { Fail 'no binary name: give -Bin <name>' }
if ($Bin -notmatch '^[A-Za-z0-9_-][A-Za-z0-9._-]*$') { Fail "'$Bin' is not a binary name" }
if (-not $env:LOCALAPPDATA) { Fail 'LOCALAPPDATA is not set' }

if ($BaseUrl) {
    $base = $BaseUrl.TrimEnd('/')
} elseif ($Version -eq 'latest') {
    $base = "https://github.com/$Repo/releases/latest/download"
} else {
    $base = "https://github.com/$Repo/releases/download/$Version"
}
# Windows on ARM runs the x86_64 build under emulation.
$platform = 'windows-x86_64'

# TLS 1.2 for Windows PowerShell 5.1, whose default may be older.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$work = Join-Path ([IO.Path]::GetTempPath()) ("install-$Bin-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $sums = Join-Path $work 'SHA256SUMS'
    try { Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile $sums }
    catch { Fail "could not download $base/SHA256SUMS: $($_.Exception.Message)" }

    $pattern = '^([0-9a-fA-F]{64}) [ *](' + [Regex]::Escape($Bin) + '-\S+-' + [Regex]::Escape($platform) + '\.zip)$'
    $found = @(Get-Content -LiteralPath $sums | ForEach-Object { $_.TrimEnd("`r") } |
        Where-Object { $_ -match $pattern } | ForEach-Object { $null = $_ -match $pattern; , @($Matches[1], $Matches[2]) })
    if ($found.Count -ne 1) { Fail "SHA256SUMS lists $($found.Count) archives for $Bin on $platform, not one" }
    $want = $found[0][0].ToLowerInvariant()
    $name = $found[0][1]

    Say "downloading $name"
    $archive = Join-Path $work $name
    try { Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile $archive }
    catch { Fail "could not download $base/${name}: $($_.Exception.Message)" }
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    if ($got -ne $want) { Fail "$name's sha256 is $got, but SHA256SUMS says ${want}: nothing is installed" }
    Say "verified $name (sha256 $got)"
    Unblock-File -LiteralPath $archive

    $unpacked = Join-Path $work 'x'
    Expand-Archive -LiteralPath $archive -DestinationPath $unpacked
    $exe = Join-Path $unpacked "$Bin.exe"
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { Fail "$name holds no $Bin.exe" }

    $dir = Join-Path $env:LOCALAPPDATA (Join-Path 'Programs' $Bin)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $program = Join-Path $dir "$Bin.exe"
    $old = "$program.old"
    Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $program) { Move-Item -LiteralPath $program -Destination $old -Force }
    Copy-Item -LiteralPath $exe -Destination $program
    Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
    Unblock-File -LiteralPath $program
    Say "installed $program"

    # The user's Path as the registry holds it (unexpanded), added to once.
    $key = 'HKCU:\Environment'
    $item = Get-Item -LiteralPath $key
    $userPath = [string]$item.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $entries = @($userPath -split ';' | Where-Object { $_ })
    $present = $entries | Where-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -ieq $dir.TrimEnd('\') }
    if ($present) {
        Say "$dir is on the user's Path already"
    } else {
        $newPath = (@($entries) + $dir) -join ';'
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        if ($item.GetValueNames() -contains 'Path') { $kind = $item.GetValueKind('Path') }
        $reg = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        try { $reg.SetValue('Path', $newPath, $kind) } finally { $reg.Close() }
        $env:Path = "$env:Path;$dir"
        Say "added $dir to the user's Path; open a new terminal to see it"
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
