<#
.SYNOPSIS
  Makes MSBuild incremental builds work after the build directory is restored from actions/cache.

  A fresh git checkout gives every source file a new modification time, which is newer than every
  cached object file, so MSBuild would rebuild everything and the cache would be useless.

  Restore: before building, set the mtime of every tracked file (main repo + submodules) to a fixed
           old date, EXCEPT files that changed between the commit recorded in the cache and the
           current commit. Those keep their fresh mtime and get rebuilt. If the old commit is not
           available (e.g. a shallow submodule) that repository is left untouched = full rebuild of it.
  Save:    after a SUCCESSFUL build, record the current commit of the main repo and of every
           submodule in the stamp file inside the build directory (which is what gets cached). The
           stamp is deliberately not written after a failed build: objects may then be older than the
           sources, and the next run must diff against the last good commit.

  Run Restore before Apply-Patches.ps1 (patched files get a new mtime and are rebuilt every run).
#>
param(
    [Parameter(Mandatory)][ValidateSet('Restore', 'Save')][string]$Mode,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path,
    [string]$StampFile = 'build/xbox-uwp-x64/cache-stamp.json'
)

$ErrorActionPreference = 'Continue'
$stampPath = Join-Path $RepoRoot $StampFile
$oldDate = [DateTime]::new(2020, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)

function Git([string]$Dir, [string[]]$GitArgs) {
    & git -C $Dir -c core.quotepath=off @GitArgs 2>$null
}

function Get-Submodules {
    Push-Location $RepoRoot
    try {
        $r = git submodule foreach --recursive --quiet 'echo $displaypath' 2>$null
        return @($r | Where-Object { $_ })
    } finally {
        Pop-Location
    }
}

function Set-OldMtimes([string]$Dir, [string]$OldSha) {
    if (-not $OldSha) { return 'no recorded commit, left untouched' }
    $skip = New-Object 'System.Collections.Generic.HashSet[string]'
    $head = (Git $Dir @('rev-parse', 'HEAD')) | Select-Object -First 1
    if ($head -ne $OldSha) {
        Git $Dir @('cat-file', '-e', "${OldSha}^{commit}") | Out-Null
        if ($LASTEXITCODE -ne 0) { return "old commit $OldSha not available, left untouched (full rebuild)" }
        foreach ($f in (Git $Dir @('diff', '--name-only', '--no-renames', $OldSha, 'HEAD'))) { [void]$skip.Add($f) }
    }
    $n = 0
    foreach ($f in (Git $Dir @('ls-files'))) {
        if ($skip.Contains($f)) { continue }
        try {
            [System.IO.File]::SetLastWriteTimeUtc((Join-Path $Dir $f), $oldDate)
            $n++
        } catch { }
    }
    return "$n files set to $($oldDate.ToString('yyyy-MM-dd')), $($skip.Count) changed file(s) keep a fresh mtime"
}

if ($Mode -eq 'Restore') {
    if (-not (Test-Path $stampPath)) {
        Write-Host 'cache: no stamp file, cold build'
        exit 0
    }
    $stamp = Get-Content $stampPath -Raw | ConvertFrom-Json
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Write-Host ('cache: main repo (' + $stamp.main + '): ' + (Set-OldMtimes $RepoRoot $stamp.main))
    $subs = @{}
    if ($stamp.subs) { $stamp.subs.PSObject.Properties | ForEach-Object { $subs[$_.Name] = $_.Value } }
    foreach ($s in (Get-Submodules)) {
        Write-Host ('cache: ' + $s + ': ' + (Set-OldMtimes (Join-Path $RepoRoot $s) $subs[$s]))
    }
    Write-Host ('cache: mtime restore took {0:N0}s' -f $sw.Elapsed.TotalSeconds)
    exit 0
}

# Save
$main = (Git $RepoRoot @('rev-parse', 'HEAD')) | Select-Object -First 1
$subs = [ordered]@{}
foreach ($s in (Get-Submodules)) {
    $subs[$s] = (Git (Join-Path $RepoRoot $s) @('rev-parse', 'HEAD')) | Select-Object -First 1
}
New-Item -ItemType Directory -Force -Path (Split-Path $stampPath) | Out-Null
@{ main = $main; subs = $subs } | ConvertTo-Json | Set-Content -Path $stampPath -Encoding utf8
Write-Host "cache: stamp written ($main, $($subs.Count) submodule(s))"
exit 0
