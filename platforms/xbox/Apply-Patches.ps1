<#
.SYNOPSIS
  Applies the small source patches the UWP (Xbox) build needs to the third-party submodules
  (extern/aurora, extern/borealis), which point at upstream repositories.

  Idempotent: a file that already contains DUSK_XBOX_UWP is skipped. Fails loudly (exit 1) when an
  anchor is not found exactly as many times as expected, which means upstream changed and the patch
  needs to be revisited. Run from ci.ps1 before configuring. See docs/xbox-port.md.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$script:failed = $false
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Patch-File([string]$Rel, [string]$Pattern, [string]$Replacement, [int]$Expected) {
    $path = Join-Path $RepoRoot $Rel
    if (-not (Test-Path $path)) {
        Write-Host "::error::patch target missing: $Rel (is the submodule checked out?)"
        $script:failed = $true
        return
    }
    $text = [System.IO.File]::ReadAllText($path)
    if ($text -match 'DUSK_XBOX_UWP') {
        Write-Host "already patched: $Rel"
        return
    }
    $count = [regex]::Matches($text, $Pattern).Count
    if ($count -ne $Expected) {
        Write-Host "::error::patch anchor in $Rel matched $count time(s), expected $Expected (upstream changed?)"
        $script:failed = $true
        return
    }
    $new = [regex]::Replace($text, $Pattern, $Replacement)
    [System.IO.File]::WriteAllText($path, $new, $utf8)
    Write-Host "patched: $Rel ($count replacement(s))"
}

# --- aurora: lib/system_info.cpp ---------------------------------------------------------------
# The Windows branch reads the CPU name through WMI (IWbemLocator, CoSetProxyBlanket, ...) and uses
# RtlGetVersion / DXGI adapter enumeration. WMI is not part of the UWP API set. Fall through to the
# generic branch (logs "Unknown" for CPU/memory/OS) on UWP. Two `#if _WIN32` lines: the include block
# at the top and the implementation block.
Patch-File 'extern/aurora/lib/system_info.cpp' '(?m)^#if _WIN32(?=\r?$)' '#if _WIN32 && !defined(DUSK_XBOX_UWP)' 2

# --- aurora: lib/card/DolphinCardPath.cpp ------------------------------------------------------
# Finds an existing Dolphin memory card through the registry and SHGetKnownFolderPath (desktop-only).
# The file's own `#if WINDOWS_STORE` branch tests a CMake variable that is never a preprocessor macro
# (and its C++/CX body is broken), so the desktop code is compiled and fails. Importing Dolphin cards
# has no use on a console, so take the generic SDL_GetPrefPath branch on UWP. Three `#if WIN32` lines:
# includes, the ANSI helper, and the ResolveDolphinCardPath implementation.
Patch-File 'extern/aurora/lib/card/DolphinCardPath.cpp' '(?m)^#if WIN32(?=\r?$)' '#if WIN32 && !defined(DUSK_XBOX_UWP)' 3

# --- borealis: src/io.cpp ----------------------------------------------------------------------
# CreateFileW is desktop-only; UWP provides CreateFile2. Shim it right after <Windows.h> so both
# uses (RandomAccessFile::open and atomic_replace) keep their code unchanged.
$shim = @'
#include <Windows.h>
#ifdef DUSK_XBOX_UWP
// UWP: CreateFileW is not in the app API set; map it onto CreateFile2.
static inline HANDLE CreateFileW(LPCWSTR name, DWORD access, DWORD share, LPSECURITY_ATTRIBUTES,
    DWORD creation, DWORD flagsAndAttributes, HANDLE) {
    CREATEFILE2_EXTENDED_PARAMETERS params{};
    params.dwSize = sizeof(params);
    params.dwFileAttributes = flagsAndAttributes & 0x0000FFFFu;
    params.dwFileFlags = flagsAndAttributes & 0xFFFF0000u;
    return CreateFile2(name, access, share, creation, &params);
}
#endif
'@
Patch-File 'extern/borealis/src/io.cpp' '(?m)^#include <Windows\.h>(?=\r?$)' $shim.TrimEnd() 1

if ($script:failed) { exit 1 }
exit 0
