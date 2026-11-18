<#
.SYNOPSIS
  Stages upstream's bundled pipeline list (initial_pipeline_cache.db) for the Xbox package.
  Called by Apply-Patches-Disc.ps1, i.e. from ci.ps1 before configure; xbox-project.cmake adds the file to
  the package root when it exists.

  WHY: without this list the game only learns a material combination when it first draws it, and the draw
  is skipped until that pipeline is compiled (pop-in while playing). With the list, Aurora knows 2,695
  pipelines from the first launch and compiles them in the background (see Apply-Patches-Shaders.ps1 for the
  order and priority). The list contains backend-neutral configurations, not compiled shaders. It is the
  same file the official desktop release and the 999sian/dusklight Xbox fork ship; the SHA-256 below is the
  one the fork pins, and I checked it against the v2.0.3 release zip (2,678 GX rows at config version 13 and
  17 RML rows at version 3, the versions this Aurora pin uses).

  Best effort: any failure only prints a warning and the build goes on without the list (exit 0). A file with
  the wrong hash is deleted so it can never end up in the package.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$url = 'https://github.com/TwilitRealm/dusklight/releases/download/v2.0.3/Dusklight-v2.0.3-win32-x86_64.zip'
$expected = '8C6C7D974946B71AEE7FA90542085B333AF9E2726B16DCCB34F808F2C0C5C2F0'
# build/ext is restored from the CI cache, so a good copy is not downloaded again.
$dir = Join-Path $RepoRoot 'build/ext/pipeline-seed'
$db = Join-Path $dir 'initial_pipeline_cache.db'

try {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if ((Test-Path $db) -and ((Get-FileHash -Path $db -Algorithm SHA256).Hash -eq $expected)) {
        Write-Host "pipeline seed: already staged ($db)"
        exit 0
    }
    Remove-Item $db -Force -ErrorAction SilentlyContinue

    $zip = Join-Path ([System.IO.Path]::GetTempPath()) 'dusklight-seed-release.zip'
    $ok = $false
    for ($try = 1; $try -le 3 -and -not $ok; $try++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
            $ok = $true
        } catch {
            Write-Host "pipeline seed: download attempt $try failed: $($_.Exception.Message)"
            Start-Sleep -Seconds (5 * $try)
        }
    }
    if (-not $ok) { throw 'download failed' }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $entry = $archive.GetEntry('initial_pipeline_cache.db')
        if (-not $entry) { throw 'initial_pipeline_cache.db is not in the release zip' }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $db, $true)
    } finally {
        $archive.Dispose()
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }

    $hash = (Get-FileHash -Path $db -Algorithm SHA256).Hash
    if ($hash -ne $expected) {
        Remove-Item $db -Force -ErrorAction SilentlyContinue
        throw "unexpected SHA-256 $hash"
    }
    Write-Host "pipeline seed: staged $db ($((Get-Item $db).Length) bytes)"
} catch {
    Write-Host "::warning::pipeline seed not staged ($($_.Exception.Message)); the package ships without initial_pipeline_cache.db"
    Remove-Item $db -Force -ErrorAction SilentlyContinue
}
exit 0
