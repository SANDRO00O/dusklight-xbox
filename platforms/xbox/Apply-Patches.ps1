<#
.SYNOPSIS
  Applies the small source patches the UWP (Xbox) build needs.

  -Phase Source (default): third-party submodules (extern/aurora, extern/borealis) and the graphics
                           probe hook in src/m_Do/m_Do_main.cpp. Run before configuring.
  -Phase Deps:             sources CMake downloads at configure time (Dawn, under
                           build/xbox-uwp-x64/_deps). Run after configuring, before building.

  Idempotent: a file that already contains DUSK_XBOX_UWP is skipped. Fails loudly (exit 1) when an
  anchor is not found exactly as many times as expected, which means upstream changed and the patch
  needs to be revisited. Called from ci.ps1. See docs/xbox-port.md.

  Every tracked file patched in the Source phase (now or in the past) must be listed in
  $alwaysFresh of Cache-Mtimes.ps1.

  NOTE (graphics backend): there is deliberately NO patch for the backend order in aurora.cpp. An
  attempt to drop D3D12 so Aurora would use D3D11 (build 789faead) failed on a real Xbox One S:
  Dawn's D3D11 backend requests feature level 11.1/11.0 and D3D11CreateDevice returns
  DXGI_ERROR_UNSUPPORTED, because Xbox One only offers D3D11 feature level 10.1 to UWP apps and
  games. On Xbox One D3D12 (FL 11.0) exists only in Game mode. Instead of guessing, the game runs
  platforms/xbox/xbox_gfx_probe.cpp (+ _deep.cpp) before Aurora (hooked in below) and picks the
  backend from it.
#>
param(
    [ValidateSet('Source', 'Deps')][string]$Phase = 'Source',
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path,
    [string]$BuildDir = 'build/xbox-uwp-x64'
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

# Several edits to one file, all or none. Every pattern's match count is checked against the original
# text first. $Edits: array of @{ Pattern = ...; Replacement = ...; Expected = n }.
function Patch-FileMulti([string]$Rel, [object[]]$Edits) {
    $path = Join-Path $RepoRoot $Rel
    if (-not (Test-Path $path)) {
        Write-Host "::error::patch target missing: $Rel"
        $script:failed = $true
        return
    }
    $text = [System.IO.File]::ReadAllText($path)
    if ($text -match 'DUSK_XBOX_UWP') {
        Write-Host "already patched: $Rel"
        return
    }
    foreach ($e in $Edits) {
        $count = [regex]::Matches($text, $e.Pattern).Count
        if ($count -ne $e.Expected) {
            Write-Host "::error::patch anchor '$($e.Pattern)' in $Rel matched $count time(s), expected $($e.Expected) (upstream changed?)"
            $script:failed = $true
            return
        }
    }
    foreach ($e in $Edits) {
        $text = [regex]::Replace($text, $e.Pattern, $e.Replacement)
    }
    [System.IO.File]::WriteAllText($path, $text, $utf8)
    Write-Host "patched: $Rel ($($Edits.Count) edit(s))"
}

if ($Phase -eq 'Source') {

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

# --- borealis: src/log.cpp ---------------------------------------------------------------------
# The log file is a stdio FILE that is only flushed for warnings and above. When the game dies with
# an access violation inside the GPU driver the crash handler appends its report to the file, but all
# earlier INFO lines are still in the stdio buffer and are lost, so the log shows nothing about how
# far Aurora/Dawn got. Debug aid: on Xbox flush after every line.
$logConst = @'
using namespace std::literals::string_view_literals;

// DUSK_XBOX_UWP: flush the log file after every line (see Apply-Patches.ps1).
#ifdef DUSK_XBOX_UWP
constexpr bool kDuskXboxFlushEveryLine = true;
#else
constexpr bool kDuskXboxFlushEveryLine = false;
#endif
'@
$logEdits = @(
    @{ Pattern = '(?m)^using namespace std::literals::string_view_literals;(?=\r?$)'; Replacement = $logConst.TrimEnd(); Expected = 1 },
    @{ Pattern = 'message\.level >= state\.options\.flushOn'; Replacement = '(message.level >= state.options.flushOn || kDuskXboxFlushEveryLine)'; Expected = 3 }
)
Patch-FileMulti 'extern/borealis/src/log.cpp' $logEdits

# --- game: src/m_Do/m_Do_main.cpp --------------------------------------------------------------
# Run the SEH-guarded graphics probe (platforms/xbox/xbox_gfx_probe*.cpp) right before Aurora creates
# the window and the GPU device. Result bits: 1 = D3D12 device creation works, 2 = D3D11 feature
# level >= 11.0 works, 4 = probe could not run. With D3D12 usable (or the probe inconclusive) Aurora
# keeps its normal Auto order (D3D12 first). D3D12 broken but D3D11 usable: force D3D11. Neither: log
# and exit instead of letting Aurora walk into the crashing D3D12 backend. Results are in
# gfx-probe.log next to the game log.
$probe = @'
#ifdef DUSK_XBOX_UWP
        {
            int dusk_xbox_probe_graphics_ex(const wchar_t* dir);
            const int xboxGfx = dusk_xbox_probe_graphics_ex(dusk::CachePath.c_str());
            DuskLog.info("Xbox graphics probe result: {} (1=D3D12, 2=D3D11 FL11, 4=inconclusive), see gfx-probe.log", xboxGfx);
            if ((xboxGfx & 4) == 0 && (xboxGfx & 1) == 0) {
                if ((xboxGfx & 2) != 0) {
                    config.desiredBackend = BACKEND_D3D11;
                } else {
                    DuskLog.warn("Xbox: no usable GPU backend, see gfx-probe.log. Exiting.");
                    borealis::log::shutdown();
                    fflush(stdout);
                    fflush(stderr);
                    return 3;
                }
            }
        }
#endif
        auroraInfo = aurora_initialize(argc, argv, &config);
'@
Patch-File 'src/m_Do/m_Do_main.cpp' '(?m)^        auroraInfo = aurora_initialize\(argc, argv, &config\);(?=\r?$)' $probe.TrimEnd() 1

}

if ($Phase -eq 'Deps') {

# --- Dawn: src/dawn/native/d3d12/D3D12Info.cpp -------------------------------------------------
# Aurora's Dawn (encounter/dawn @ 1155e0ed) fills D3D12DeviceInfo with ~14 optional
# ID3D12Device::CheckFeatureSupport queries. On the Xbox One S the user-mode driver (umd12ddi.dll)
# raises an access violation inside D3D12 device initialisation. The queries are optional (every
# result only sets a capability flag that defaults to false), so route them all through a helper
# that runs the call under SEH and treats an exception as "not supported". 16 call sites: 14 in
# GatherDeviceInfo plus 2 in the Agility-SDK-only linear algebra helper.
$safeHelper = @'
namespace dawn::native::d3d12 {

// DUSK_XBOX_UWP: the Xbox One S user-mode driver can raise an access violation for CheckFeatureSupport
// queries it does not know. Treat that as "feature not supported".
static HRESULT DuskSafeCheckFeatureSupport(ID3D12Device* device, D3D12_FEATURE feature, void* data, UINT size) {
    HRESULT hr = E_FAIL;
    __try {
        hr = device->CheckFeatureSupport(feature, data, size);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        hr = E_FAIL;
    }
    return hr;
}
'@
$edits = @(
    @{ Pattern = '(?m)^namespace dawn::native::d3d12 \{(?=\r?$)'; Replacement = $safeHelper.TrimEnd(); Expected = 1 },
    @{ Pattern = 'd3d12Device->CheckFeatureSupport\('; Replacement = 'DuskSafeCheckFeatureSupport(d3d12Device.Get(), '; Expected = 16 }
)
Patch-FileMulti "$BuildDir/_deps/dawn-src/src/dawn/native/d3d12/D3D12Info.cpp" $edits

}

if ($script:failed) { exit 1 }
exit 0
