# install.ps1 against a fake release served over http (python's http.server),
# with LOCALAPPDATA in a temporary directory. It writes the user's Path in
# HKCU, so run it on a throwaway machine (the self-test's runner). Each case
# prints `ok <case>`; a failure throws.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$installer = Join-Path $PSScriptRoot '..\installers\install.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ('install-test-' + [Guid]::NewGuid().ToString('N'))
$rel = Join-Path $work 'release'
New-Item -ItemType Directory -Force -Path $rel, (Join-Path $work 'stage') | Out-Null
$shell = (Get-Process -Id $PID).Path

# A stand-in demo.exe: any real exe (where.exe), renamed.
Copy-Item (Join-Path $env:SystemRoot 'System32\where.exe') (Join-Path $work 'stage\demo.exe')
$archive = 'demo-0.1.0+abc1234-windows-x86_64.zip'
Compress-Archive -Path (Join-Path $work 'stage\demo.exe') -DestinationPath (Join-Path $rel $archive)
Copy-Item (Join-Path $rel $archive) (Join-Path $rel 'demo-0.1.0+abc1234-linux-x86_64.tar.gz')
function Write-Sums {
    $lines = Get-ChildItem -LiteralPath $rel -Filter 'demo-*' | ForEach-Object {
        '{0}  {1}' -f (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant(), $_.Name
    }
    [IO.File]::WriteAllText((Join-Path $rel 'SHA256SUMS'), (($lines -join "`n") + "`n"))
}
Write-Sums

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
$server = Start-Process -PassThru -WindowStyle Hidden python -ArgumentList '-m', 'http.server', $port, '--bind', '127.0.0.1', '--directory', $rel
try {
    $url = "http://127.0.0.1:$port"
    foreach ($i in 1..50) {
        try { Invoke-WebRequest -UseBasicParsing "$url/SHA256SUMS" | Out-Null; break } catch { Start-Sleep -Milliseconds 200 }
    }

    function Invoke-Installer([string]$AppData, [string[]]$Arguments) {
        $env:LOCALAPPDATA = $AppData
        $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $installer -BaseUrl $url @Arguments 2>&1 | Out-String
        return @{ Code = $LASTEXITCODE; Out = $out }
    }

    $appData = Join-Path $work 'appdata1'
    $r = Invoke-Installer $appData @('-Repo', 'ctxloom/demo', '-Bin', 'demo')
    if ($r.Code -ne 0) { throw "install: exit $($r.Code): $($r.Out)" }
    $dir = Join-Path $appData 'Programs\demo'
    $program = Join-Path $dir 'demo.exe'
    if (-not (Test-Path -LiteralPath $program)) { throw "install: no $program" }
    if (Get-Item -LiteralPath $program -Stream Zone.Identifier -ErrorAction SilentlyContinue) { throw 'install: the exe keeps a Mark-of-the-Web' }
    $reg = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    $userPath = [string]$reg.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $reg.Close()
    if (@($userPath -split ';' | Where-Object { $_ -ieq $dir }).Count -ne 1) { throw "install: $dir is not on the user's Path once: $userPath" }
    'ok install'

    $r = Invoke-Installer $appData @('-Repo', 'ctxloom/demo', '-Bin', 'demo')
    if ($r.Code -ne 0) { throw "reinstall: exit $($r.Code): $($r.Out)" }
    $reg = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    $userPath = [string]$reg.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $reg.Close()
    if (@($userPath -split ';' | Where-Object { $_ -ieq $dir }).Count -ne 1) { throw "reinstall: $dir is on the user's Path more than once" }
    if (@(Get-ChildItem -LiteralPath $dir).Count -ne 1) { throw "reinstall: left files beside the exe" }
    'ok reinstall, the Path added to once'

    $good = Join-Path $work 'good.zip'
    Copy-Item (Join-Path $rel $archive) $good
    Add-Content -LiteralPath (Join-Path $rel $archive) -Value 'tampered'
    $appData = Join-Path $work 'appdata2'
    $r = Invoke-Installer $appData @('-Repo', 'ctxloom/demo', '-Bin', 'demo')
    Copy-Item $good (Join-Path $rel $archive) -Force
    if ($r.Code -eq 0) { throw "tampered: installed: $($r.Out)" }
    if ($r.Out -notmatch 'sha256 is') { throw "tampered: no checksum message: $($r.Out)" }
    if (Test-Path -LiteralPath (Join-Path $appData 'Programs\demo\demo.exe')) { throw 'tampered: installed the exe' }
    'ok tampered archive refused'

    $r = Invoke-Installer (Join-Path $work 'appdata3') @('-Repo', 'ctxloom/demo', '-Bin', 'nothing')
    if ($r.Code -eq 0 -or $r.Out -notmatch 'lists 0 archives') { throw "no archive: exit $($r.Code): $($r.Out)" }
    'ok no archive refused'
} finally {
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
# The installer runs above left their exit codes behind; this script passed.
$global:LASTEXITCODE = 0
