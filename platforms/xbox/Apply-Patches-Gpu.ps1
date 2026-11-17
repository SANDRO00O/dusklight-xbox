<#
.SYNOPSIS
  Dawn device toggle for the Xbox One S. Called by Apply-Patches-Disc.ps1, i.e. from ci.ps1 before configure.

  Adds the Dawn toggle "disable_resource_suballocation" to the device toggles in
  extern/aurora/lib/webgpu/gpu.cpp (the `enableToggles` list passed to RequestDevice) on UWP.

  WHY: the Xbox One S D3D12 driver faults in ID3D12Device::CreatePlacedResource, which Dawn uses when it
  suballocates buffers/textures out of large heaps (our graphics probe caught an access violation on a 64 MiB
  placed upload heap). With the toggle Dawn creates committed resources instead and never calls
  CreatePlacedResource for them. The fork 999sian/dusklight (also an Xbox One S port of Dusklight) ships the
  same toggle under #ifdef AURORA_WINDOWS_STORE for the same crash and verified it on hardware.
  Trade-off: somewhat more GPU memory overhead and slower resource creation; both acceptable here.

  Idempotent (marker dusk_xbox_suballoc). Exits 1 when the anchor does not match exactly once.
  The patched file must be listed in $alwaysFresh of Cache-Mtimes.ps1.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$marker = 'dusk_xbox_suballoc'
$rel = 'extern/aurora/lib/webgpu/gpu.cpp'

$path = Join-Path $RepoRoot $rel
if (-not (Test-Path $path)) {
    Write-Host "::error::patch target missing: $rel (is the submodule checked out?)"
    exit 1
}
$text = [System.IO.File]::ReadAllText($path)
if ($text.Contains($marker)) {
    Write-Host "already patched: $rel"
    exit 0
}

$pattern = '(?m)^    constexpr std::array enableToggles\{\r?\n#if _WIN32(?=\r?$)'
$count = [regex]::Matches($text, $pattern).Count
if ($count -ne 1) {
    Write-Host "::error::patch anchor 'enableToggles' in $rel matched $count time(s), expected 1 (upstream changed?)"
    exit 1
}

$replacement = @'
    constexpr std::array enableToggles{
#ifdef DUSK_XBOX_UWP
        // dusk_xbox_suballoc: the Xbox One S D3D12 driver faults in CreatePlacedResource (Dawn's resource
        // suballocation); use committed resources instead. See Apply-Patches-Gpu.ps1.
        "disable_resource_suballocation",
#endif
#if _WIN32
'@
$text = [regex]::Replace($text, $pattern, $replacement.TrimEnd().Replace('$', '$$'))
[System.IO.File]::WriteAllText($path, $text, $utf8)
Write-Host "patched: $rel (disable_resource_suballocation toggle on UWP)"
exit 0
