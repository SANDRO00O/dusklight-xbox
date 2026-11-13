<#
.SYNOPSIS
  Applies the small source patches the UWP (Xbox) build needs to the third-party submodules
  (extern/aurora, extern/borealis), which point at upstream repositories.

  Idempotent: a file that already contains DUSK_XBOX_UWP is skipped. Fails loudly (exit 1) when an
  anchor is not found exactly as many times as expected, which means upstream changed and the patch
  needs to be revisited. Run from ci.ps1 before configuring. See docs/xbox-port.md.

  NOTE (graphics backend): there is deliberately NO patch for the backend order. An attempt to drop
  D3D12 so Aurora would use D3D11 (build 789faead) failed on a real Xbox One S: Dawn's D3D11 backend
  requests feature level 11.1/11.0 and D3D11CreateDevice returns DXGI_ERROR_UNSUPPORTED, because
  Xbox One only offers D3D11 feature level 10.1 to UWP apps and games. On Xbox One D3D12 (FL 11.0)
  exists only when the package runs in Game mode (Dev Home > Games & apps > Dusklight > View >
  View details > App type = Game). In App mode d3d12.dll loads but the driver (umd12ddi.dll) crashes.
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

# --- aurora: cmake/AuroraCopyRuntimeDLLs.cmake -------------------------------------------------
# aurora_copy_runtime_dlls() adds a POST_BUILD `cmake -E copy_if_different $<TARGET_RUNTIME_DLLS:...>
# <dir>`. With only static libraries the DLL list is empty, so cmake prints its usage and the build
# fails after a successful link. There are no runtime DLLs to copy (or install) for UWP, so return
# early from both helper functions (two `  if (NOT WIN32)` lines).
Patch-File 'extern/aurora/cmake/AuroraCopyRuntimeDLLs.cmake' '(?m)^  if \(NOT WIN32\)(?=\r?$)' '  if (NOT WIN32 OR DUSK_PLATFORM_XBOX) # DUSK_XBOX_UWP: static libs, no runtime DLLs' 2

# --- aurora: lib/dawn/BackendBinding.cpp -------------------------------------------------------
# Only a Win32 HWND surface exists. SDL3-uwp has no HWND; it exposes the CoreWindow (an IInspectable)
# as SDL_PROP_WINDOW_WINRT_WINDOW_POINTER. Dawn's CoreWindow surface type is the Dawn-specific
# SurfaceDescriptorFromWindowsCoreWindow (dawn.json: "surface descriptor from windows core window",
# member coreWindow); the SurfaceSource* spelling only exists for the standardised types such as
# HWND. The branch goes before the SDL_PLATFORM_WIN32 one so it wins even if the fork defines both.
$surface = @'
#elif defined(DUSK_XBOX_UWP)
  std::shared_ptr<wgpu::SurfaceDescriptorFromWindowsCoreWindow> desc =
      std::make_shared<wgpu::SurfaceDescriptorFromWindowsCoreWindow>();
  desc->coreWindow = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WINRT_WINDOW_POINTER, nullptr);
  return std::move(desc);
#elif defined(SDL_PLATFORM_WIN32)
'@
Patch-File 'extern/aurora/lib/dawn/BackendBinding.cpp' '(?m)^#elif defined\(SDL_PLATFORM_WIN32\)\r?$' ($surface -replace '\r?\n$', '') 1

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
