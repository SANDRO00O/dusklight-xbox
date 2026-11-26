<#
.SYNOPSIS
  Native (code) mods on the Xbox: export the WebGPU API (wgpu*) from dusklight.exe. Called by
  Apply-Patches-Disc.ps1. Patches cmake/WindowsExports.cmake only (a CMake file, no object to keep fresh).

  FOUND ON HARDWARE (dusklight log of 2026-11-26, rev 54a7019, import diagnostic of Apply-Patches-NativeDiag.ps1):
    Deferred Fog:               11 unresolved imports, all dusklight.exe!wgpu...
    Cinematic Depth of Field:   15 unresolved imports, all dusklight.exe!wgpu...
  so "The specified procedure could not be found" (error 127) is the missing WebGPU exports.

  Cause: upstream's setup_windows_exports() hands the exe's export list to symgen with the Aurora SDK libraries,
  and for Dawn only handles a SHARED webgpu_dawn.dll (the Windows default): the exe then forwards every wgpu*
  symbol to the DLL (--forward-dll / --forward-sym-prefix). The Xbox build links Dawn STATIC
  (AURORA_DAWN_LINKAGE static in cmake/toolchains/xbox-uwp-x64.cmake), so nothing exported wgpu* at all.
  cmake/AppleExports.cmake already has the static case ("Dawn is linked statically on Apple; mods reach wgpu*
  through the executable"): the Dawn library is passed to symgen as another --sdk-lib. This patch does the same
  for Windows.

  Not verified: how many symbols symgen takes from the Dawn library (the .def has --max-exports 58000, the PE
  limit is 65535). If the link fails on the export count, ci.ps1 falls back to a build without mods.

  Idempotent (marker dusk_xbox_static_dawn_exports). Exits 1 when the anchor does not match exactly once.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$marker = 'dusk_xbox_static_dawn_exports'

$rel = 'cmake/WindowsExports.cmake'
$path = Join-Path $RepoRoot $rel
if (-not (Test-Path $path)) {
    Write-Host "::error::patch target missing: $rel"
    exit 1
}
$text = [System.IO.File]::ReadAllText($path)
if ($text.Contains($marker)) {
    Write-Host "already patched: $rel"
    exit 0
}

$pattern = '(?m)^                    --forward-sym-prefix wgpu\)(?=\r?$)'
$count = [regex]::Matches($text, $pattern).Count
if ($count -ne 1) {
    Write-Host "::error::patch anchor '$pattern' in $rel matched $count time(s), expected 1 (upstream changed?)"
    exit 1
}

$replacement = @'
                    --forward-sym-prefix wgpu)
        elseif (_dawn_type STREQUAL "STATIC_LIBRARY")
            # dusk_xbox_static_dawn_exports: static Dawn (Xbox UWP build): mods reach wgpu* through the
            # executable, like cmake/AppleExports.cmake (platforms/xbox/Apply-Patches-ModExports.ps1).
            list(APPEND _sdk_args --sdk-lib "$<TARGET_FILE:dawn::webgpu_dawn>")
'@
$text = [regex]::Replace($text, $pattern, $replacement.TrimEnd().Replace('$', '$$'))
[System.IO.File]::WriteAllText($path, $text, $utf8)
Write-Host "patched: $rel (static Dawn exported through the executable)"
exit 0
