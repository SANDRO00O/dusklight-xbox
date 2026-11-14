<#
.SYNOPSIS
  Makes MSBuild incremental builds work after the build directory is restored from actions/cache.

  A fresh git checkout gives every source file a new modification time, which is newer than every
  cached object file, so MSBuild would rebuild everything and the cache would be useless.

  Restore: before building, set the mtime of every tracked file (main repo + submodules) to a fixed
           old date, EXCEPT files that changed between the commit recorded in the cache and the
           current commit, and EXCEPT the files Apply-Patches.ps1 modifies (listed below). Those keep
           their fresh mtime and get rebuilt. If the old commit is not available (e.g. a shallow
           submodule) that repository is left untouched = full rebuild of it.
  Save:    after a SUCCESSFUL build, record the current commit of the main repo and of every
           submodule in the stamp file inside the build directory (which is what gets cached). The
           stamp is deliberately not written after a failed build: objects may then be older than the
           sources, and the next run must diff against the last good commit.

  Run Restore before Apply-Patches.ps1 (patched files get a new mtime and are rebuilt every run).

  RULE: every file Apply-Patches.ps1 has ever patched must stay in $alwaysFresh, even after the
  patch is removed. The cached object was compiled from the PATCHED text; once the patch is gone the
  file is clean in git, would get the old mtime, and the stale object would be linked.
#>
param(
    [Parameter(Mandatory)][ValidateSet('Restore', 'Save')][string]$Mode,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path,
    [string]$StampFile = 'build/xbox-uwp-x64/cache-stamp.json'
)

$ErrorActionPreference = 'Continue'
$stampPath = Join-Path $RepoRoot $StampFile
$oldDate = [DateTime]::new(2020, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)

# Paths relative to the repository root, forward slashes.
$alwaysFresh = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($p in @(
    'extern/aurora/lib/system_info.cpp',
    'extern/aurora/lib/card/DolphinCardPath.cpp',
    'extern/aurora/cmake/AuroraCopyRuntimeDLLs.cmake',
    'extern/aurora/lib/dawn/BackendBinding.cpp',
    'extern/aurora/lib/aurora.cpp',          # patched in build 789faead (D3D12 skip), patch since removed
    'extern/borealis/src/io.cpp',
    'extern/borealis/src/log.cpp',           # flush the log file on every line
    'src/m_Do/m_Do_main.cpp'                 # graphics probe hook
)) { [void]$alwaysFresh.Add($p) }

# One-off: the first cached build (workflow run 117453502716, commit below) wrote an empty stamp
# because of a bug in this script (a function named Git shadowed git.exe and recursed). Its objects
# were built from this commit with unchanged submodules, so use it when the stamp has no commit.
$bootstrapCommit = '789faead42f9353d38e0010dd787bb13725d14f2'

# NOT named Git: PowerShell command names are case-insensitive and functions win over executables.
function Invoke-Git([string]$Dir, [string[]]$GitArgs) {
    & git.exe -C $Dir -c core.quotepath=off @GitArgs 2>$null
}

function Get-Submodules {
    Push-Location $RepoRoot
    try {
        $r = git.exe submodule foreach --recursive --quiet 'echo $displaypath' 2>$null
        return @($r | Where-Object { $_ })
    } finally {
        Pop-Location
    }
}

# $RelDir: the directory's path relative to the repo root ('' for the main repo), for $alwaysFresh.
function Set-OldMtimes([string]$Dir, [string]$RelDir, [string]$OldSha) {
    if (-not $OldSha) { return 'no recorded commit, left untouched' }
    $skip = New-Object 'System.Collections.Generic.HashSet[string]'
    $head = (Invoke-Git $Dir @('rev-parse', 'HEAD')) | Select-Object -First 1
    if ($head -ne $OldSha) {
        Invoke-Git $Dir @('cat-file', '-e', "${OldSha}^{commit}") | Out-Null
        if ($LASTEXITCODE -ne 0) { return "old commit $OldSha not available, left untouched (full rebuild)" }
        foreach ($f in (Invoke-Git $Dir @('diff', '--name-only', '--no-renames', $OldSha, 'HEAD'))) { [void]$skip.Add($f) }
    }
    $prefix = if ($RelDir) { ($RelDir -replace '\\', '/') + '/' } else { '' }
    $n = 0
    $fresh = 0
    foreach ($f in (Invoke-Git $Dir @('ls-files'))) {
        if ($skip.Contains($f)) { continue }
        if ($alwaysFresh.Contains($prefix + $f)) { $fresh++; continue }
        try {
            [System.IO.File]::SetLastWriteTimeUtc((Join-Path $Dir $f), $oldDate)
            $n++
        } catch { }
    }
    return "$n files set to $($oldDate.ToString('yyyy-MM-dd')), $($skip.Count) changed + $fresh patched file(s) keep a fresh mtime"
}

if ($Mode -eq 'Restore') {
    if (-not (Test-Path $stampPath)) {
        Write-Host 'cache: no stamp file, cold build'
        exit 0
    }
    $stamp = Get-Content $stampPath -Raw | ConvertFrom-Json
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $subs = @{}
    if ($stamp.subs) { $stamp.subs.PSObject.Properties | ForEach-Object { $subs[$_.Name] = $_.Value } }
    $mainOld = $stamp.main
    $bootstrapped = $false
    if (-not $mainOld) {
        $mainOld = $bootstrapCommit
        $bootstrapped = $true
        Write-Host "cache: stamp has no commit, assuming the cache was built from $bootstrapCommit"
    }
    Write-Host ('cache: main repo (' + $mainOld + '): ' + (Set-OldMtimes $RepoRoot '' $mainOld))
    foreach ($s in (Get-Submodules)) {
        $subOld = $subs[$s]
        if (-not $subOld -and $bootstrapped) {
            # Bootstrap only: the submodule pins did not change since that build, so use what the
            # superproject commit recorded then.
            $subOld = ((Invoke-Git $RepoRoot @('ls-tree', $mainOld, $s)) | Select-Object -First 1) -replace '^\d+\s+commit\s+([0-9a-f]{40}).*$', '$1'
            if ($subOld -notmatch '^[0-9a-f]{40}$') { $subOld = $null }
        }
        Write-Host ('cache: ' + $s + ': ' + (Set-OldMtimes (Join-Path $RepoRoot $s) $s $subOld))
    }
    Write-Host ('cache: mtime restore took {0:N0}s' -f $sw.Elapsed.TotalSeconds)
    exit 0
}

# Save
$main = (Invoke-Git $RepoRoot @('rev-parse', 'HEAD')) | Select-Object -First 1
if (-not $main) {
    Write-Host '::warning::cache: could not read HEAD, stamp not written'
    exit 0
}
$subs = [ordered]@{}
foreach ($s in (Get-Submodules)) {
    $subs[$s] = (Invoke-Git (Join-Path $RepoRoot $s) @('rev-parse', 'HEAD')) | Select-Object -First 1
}
New-Item -ItemType Directory -Force -Path (Split-Path $stampPath) | Out-Null
@{ main = $main; subs = $subs } | ConvertTo-Json | Set-Content -Path $stampPath -Encoding utf8
Write-Host "cache: stamp written ($main, $($subs.Count) submodule(s))"
exit 0
