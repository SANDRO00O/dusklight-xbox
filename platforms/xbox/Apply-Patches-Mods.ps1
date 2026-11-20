<#
.SYNOPSIS
  Native (code) mods on the Xbox build. Called by ci.ps1. Patches CMakeLists.txt only.

  With DUSK_ENABLE_CODE_MODS on (platforms/xbox/code-mods.txt, read by the toolchain file) the top-level
  CMakeLists.txt adds the in-tree mods (mods/luau_runtime, mods/template_mod, ...) as subdirectories. They
  are desktop-style mod projects (own dependencies, link stubs) that are not meant for the UWP build and are
  not needed to run mods, so they are skipped when DUSK_PLATFORM_XBOX is set.
  The game, funchook (platforms/xbox/PatchFunchookUwp.cmake), the exported symbol list and the symbol
  manifest are built by the unchanged upstream CMake code.

  Idempotent (marker 'AND NOT DUSK_PLATFORM_XBOX'). Exits 1 when the anchor does not match exactly once.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

$rel = 'CMakeLists.txt'
$path = Join-Path $RepoRoot $rel
if (-not (Test-Path $path)) {
    Write-Host "::error::patch target missing: $rel"
    exit 1
}
$text = [System.IO.File]::ReadAllText($path)
if ($text.Contains('AND NOT DUSK_PLATFORM_XBOX')) {
    Write-Host "already patched: $rel"
    exit 0
}
$pattern = '(?m)^if \(DUSK_ENABLE_CODE_MODS AND CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR\)(?=\r?$)'
$count = [regex]::Matches($text, $pattern).Count
if ($count -ne 1) {
    Write-Host "::error::patch anchor '$pattern' in $rel matched $count time(s), expected 1 (upstream changed?)"
    exit 1
}
$replacement = 'if (DUSK_ENABLE_CODE_MODS AND NOT DUSK_PLATFORM_XBOX AND CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)'
$text = [regex]::Replace($text, $pattern, $replacement)
[System.IO.File]::WriteAllText($path, $text, $utf8)
Write-Host "patched: $rel (in-tree mods are not added on Xbox)"
exit 0
