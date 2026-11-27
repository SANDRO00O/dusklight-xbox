<#
.SYNOPSIS
  Native mods on the Xbox: make funchook hook functions it gave up on. Called by ci.ps1 right after configure
  (CMake has fetched and patched funchook by then, see PatchFunchookUwp.cmake), before the build.

  FOUND ON HARDWARE (dusklight log of 2026-11-26, Deferred Fog / Twilit Essentials): some hooks fail with
    "Could not fix ip-relative address. The size is not 32."   (funchook_prepare returns 5)
    "Too short instructions"                                    (funchook_prepare returns 7)
  Causes (funchook v1.1.3, src/funchook_x86.c):
   * It copies the first >= 5 bytes of the hooked function into a trampoline and fixes ip-relative operands, but
     only 32-bit ones. MSVC starts many functions with an early-out (test ecx,ecx / je short ...), a 2-byte
     JMP/Jcc rel8, and funchook gives up on it.
   * distorm decodes with DF_STOP_ON_RET, so a function that ends inside the first 5 bytes ("xor eax,eax; ret")
     is "too short" unless NOPs follow. MSVC pads with INT3 (0xCC), not NOP. (And when it did succeed, the
     trampoline's first 4 bytes were overwritten with garbage because the jump-back slot stayed empty.)
  platforms/xbox/funchook/funchook_x86.{c,h} are v1.1.3 with: JMP/Jcc rel8 widened to the rel32 form inside the
  trampoline, INT3 accepted as padding, a valid jump-back for functions that end in the patched bytes, and 6
  fix-up slots instead of 2. Tested on Linux x86-64 against the original (the original fails with exactly the
  two errors above, the modified files hook all test functions and the hooked functions return correct values).

  Idempotent (marker dusk_xbox_rel8). Exits 1 when funchook's sources are missing or are not the expected version.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path,
    [string]$BuildDir = 'build/xbox-uwp-x64'
)

$ErrorActionPreference = 'Stop'
$marker = 'dusk_xbox_rel8'

$depsDir = Join-Path (Join-Path $RepoRoot $BuildDir) '_deps'
$srcDir = $null
if (Test-Path $depsDir) {
    $cand = Join-Path $depsDir 'funchook-src/src'
    if (Test-Path (Join-Path $cand 'funchook_x86.c')) { $srcDir = $cand }
}
if (-not $srcDir) {
    $found = Get-ChildItem -Path $depsDir -Recurse -Filter 'funchook_x86.c' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $srcDir = $found.DirectoryName }
}
if (-not $srcDir) {
    Write-Host "::error::funchook sources (funchook_x86.c) not found under $depsDir"
    exit 1
}

$target = Join-Path $srcDir 'funchook_x86.c'
$targetH = Join-Path $srcDir 'funchook_x86.h'
$current = [System.IO.File]::ReadAllText($target)
if ($current.Contains($marker)) {
    Write-Host "already patched: $target"
    exit 0
}
if (-not $current.Contains('Could not fix ip-relative address. The size is not 32.') -or
    -not ([System.IO.File]::ReadAllText($targetH)).Contains('#define TRAMPOLINE_SIZE (JUMP32_SIZE + (MAX_INSN_LEN - 1) + JUMP32_SIZE)')) {
    Write-Host "::error::funchook sources in $srcDir are not the expected v1.1.3 (anchor text missing)"
    exit 1
}

$mineDir = Join-Path $PSScriptRoot 'funchook'
foreach ($name in 'funchook_x86.c', 'funchook_x86.h') {
    $mine = Join-Path $mineDir $name
    if (-not (Test-Path $mine)) {
        Write-Host "::error::patched funchook file missing: $mine"
        exit 1
    }
    Copy-Item -Force $mine (Join-Path $srcDir $name)
    # a fresh mtime so MSBuild rebuilds funchook
    (Get-Item (Join-Path $srcDir $name)).LastWriteTime = Get-Date
}
Write-Host "patched: funchook_x86.c / funchook_x86.h in $srcDir (short branches, INT3 padding, 6 fix-up slots)"
exit 0
