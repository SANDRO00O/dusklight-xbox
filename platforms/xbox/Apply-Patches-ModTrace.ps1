<#
.SYNOPSIS
  Mod loading breadcrumbs for the Xbox build. Called by Apply-Patches-Disc.ps1.

  FOUND ON HARDWARE (logs of 2026-11-26, mod "Twilit Essentials" installed): every launch dies right after
    "[dusk] Initializing mods..." / "[dusk::mods::manifest] no symbol manifest embedded"
  without a single further line (no "found '<mod>'", no error), and crash-diag.log records no exception,
  abort or terminate either. Which step of the mod loader kills the process is unknown, so this logs one INFO line
  (flushed per line, see Apply-Patches.ps1 / log.cpp) BEFORE each step:
    src/dusk/mods/loader/loader.cpp   ModLoader::init:  cache cleanup, package scan (+ package count)
                                      try_load_mod:     opening the package, reading mod.json, native code check
                                      activate_mod:     hook resolution, mod_initialize
    src/dusk/mods/loader/natives.cpp  load_native:      extracting runtime files, loading the library, symbol lookup
  All lines start with "[trace +<ms>ms]": milliseconds since the first trace line (one shared clock, dusk_trace_ms()),
  so a slow step (the multi-minute freeze after installing Twilit Essentials) shows up as a gap. The last [trace] line
  of a crashing launch is the step that never returned.
  src/dusk/mods/svc/hook.cpp: when funchook fails for a target, an extra "[diag]" warning gives the module, its RVA
  (resolve it with the symbol table / map of that build) and the first bytes of the function.
  Only logging; nothing else changes.

  Idempotent (marker dusk_xbox_modtrace per file). Exits 1 when an anchor does not match exactly once.
  All three files must be listed in $alwaysFresh of Cache-Mtimes.ps1.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$script:failed = $false
$utf8 = New-Object System.Text.UTF8Encoding($false)
$marker = 'dusk_xbox_modtrace'

function Patch-Trace([string]$Rel, [object[]]$Edits) {
    $path = Join-Path $RepoRoot $Rel
    if (-not (Test-Path $path)) {
        Write-Host "::error::patch target missing: $Rel"
        $script:failed = $true
        return
    }
    $text = [System.IO.File]::ReadAllText($path)
    if ($text.Contains($marker)) {
        Write-Host "already patched: $Rel"
        return
    }
    foreach ($e in $Edits) {
        $count = [regex]::Matches($text, $e.Pattern).Count
        if ($count -ne 1) {
            Write-Host "::error::patch anchor '$($e.Pattern)' in $Rel matched $count time(s), expected 1 (upstream changed?)"
            $script:failed = $true
            return
        }
    }
    foreach ($e in $Edits) {
        $text = [regex]::Replace($text, $e.Pattern, $e.Replacement.Replace('$', '$$'))
    }
    [System.IO.File]::WriteAllText($path, $text, $utf8)
    Write-Host "patched: $Rel ($($Edits.Count) edit(s))"
}

# --- replacement texts -----------------------------------------------------------------------
$r0 = @'
    // dusk_xbox_modtrace (platforms/xbox/Apply-Patches-ModTrace.ps1)
    Log.info("[trace +{}ms] opening package {}", dusk_trace_ms(), data::abbreviated_path_string(modPath));
    if (bundle == nullptr) {
'@
$r1 = @'
    Log.info("[trace +{}ms] reading mod.json of {}", dusk_trace_ms(), data::abbreviated_path_string(modPath));
    LoadedManifest manifest;
'@
$r2 = @'
    log::write(mod.metadata.id, LOG_LEVEL_INFO, "[trace +{}ms] checking for native code", dusk_trace_ms());
    if (load_native_if_present(mod) && mod.native) {
'@
$r3 = @'
        log::write(mod.metadata.id, LOG_LEVEL_INFO, "[trace +{}ms] resolving hooks", dusk_trace_ms());
        svc::hook_resolve_mod_records(mod);
'@
$r4 = @'
    const char* initializeName = mod.native ? "mod_initialize" : "runtime activate";
    log::write(mod.metadata.id, LOG_LEVEL_INFO, "[trace +{}ms] calling {}", dusk_trace_ms(), initializeName);
'@
$r5 = @'
    Log.info("[trace +{}ms] init: clearing the native cache {}", dusk_trace_ms(), data::abbreviated_path_string(m_cacheDir));
    // Stale libs from previous sessions (see load_native).
'@
$r6 = @'
    Log.info("[trace +{}ms] init: scanning mod packages", dusk_trace_ms());
    const auto packages = scan_packages(m_searchDirs);
    Log.info("[trace +{}ms] init: {} package(s) found", dusk_trace_ms(), packages.size());
'@
$r7 = @'
        // dusk_xbox_modtrace (platforms/xbox/Apply-Patches-ModTrace.ps1)
        log::write(mod.metadata.id, LOG_LEVEL_INFO, "[trace +{}ms] extracting native runtime files to {}", dusk_trace_ms(),
            data::abbreviated_path_string(runtimeDir));
        const std::string platformPrefix = fmt::format(
'@
$r8 = @'
    log::write(mod.metadata.id, LOG_LEVEL_INFO, "[trace +{}ms] loading native library {}", dusk_trace_ms(),
        data::abbreviated_path_string(libPath));
    auto nativeMod = std::make_unique<NativeMod>();
'@
$r9 = @'
    log::write(mod.metadata.id, LOG_LEVEL_INFO, "[trace +{}ms] native library loaded, looking up exports", dusk_trace_ms());
    nativeMod->meta = nativeMod->handle->LookupSymbol<const ModMeta*>("mod_meta");
'@

$r10 = @'
#include <variant>

// dusk_xbox_modtrace (platforms/xbox/Apply-Patches-ModTrace.ps1): one clock for all [trace] lines
#include <chrono>
inline long long dusk_trace_ms() {
    static const auto t0 = std::chrono::steady_clock::now();
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
}
'@
$r11 = @'
        *mod.native->contextSymbol = mod.context.get();
        log::write(mod.metadata.id, LOG_LEVEL_INFO, "[trace +{}ms] hooks resolved", dusk_trace_ms());
'@
$r12 = @'
    log::write(mod.metadata.id, LOG_LEVEL_INFO, "[trace +{}ms] {} returned (initialized={}, loadFailed={})", dusk_trace_ms(),
        initializeName, mod.initialized, mod.loadFailed);
    warn_unpublished_deferred_exports(mod);
'@

# --- loader.cpp ----------------------------------------------------------------------------------
Patch-Trace 'src/dusk/mods/loader/loader.cpp' @(
    # try_load_mod: opening the package (zip / directory)
    @{ Pattern = '(?m)^    if \(bundle == nullptr\) \{(?=\r?$)';
       Replacement = $r0.TrimEnd() },
    # try_load_mod: mod.json
    @{ Pattern = '(?m)^    LoadedManifest manifest;(?=\r?$)';
       Replacement = $r1.TrimEnd() },
    # try_load_mod: native code
    @{ Pattern = '(?m)^    if \(load_native_if_present\(mod\) && mod\.native\) \{(?=\r?$)';
       Replacement = $r2.TrimEnd() },
    # activate_mod: hook resolution
    @{ Pattern = '(?m)^        svc::hook_resolve_mod_records\(mod\);(?=\r?$)';
       Replacement = $r3.TrimEnd() },
    # activate_mod: mod_initialize
    @{ Pattern = '(?m)^    const char\* initializeName = mod\.native \? "mod_initialize" : "runtime activate";(?=\r?$)';
       Replacement = $r4.TrimEnd() },
    # init: cache cleanup (the comment line is the anchor, the statement follows it)
    @{ Pattern = '(?m)^    // Stale libs from previous sessions \(see load_native\)\.(?=\r?$)';
       Replacement = $r5.TrimEnd() },
    # init: package scan
    @{ Pattern = '(?m)^    const auto packages = scan_packages\(m_searchDirs\);(?=\r?$)';
       Replacement = $r6.TrimEnd() },
    # shared clock
    @{ Pattern = '(?m)^#include <variant>(?=\r?$)';
       Replacement = $r10.TrimEnd() },
    # activate_mod: after the hooks were resolved
    @{ Pattern = '(?m)^        \*mod\.native->contextSymbol = mod\.context\.get\(\);(?=\r?$)';
       Replacement = $r11.TrimEnd() },
    # activate_mod: mod_initialize finished
    @{ Pattern = '(?m)^    warn_unpublished_deferred_exports\(mod\);(?=\r?$)';
       Replacement = $r12.TrimEnd() }
)

# --- natives.cpp ---------------------------------------------------------------------------------
Patch-Trace 'src/dusk/mods/loader/natives.cpp' @(
    @{ Pattern = '(?m)^#include <variant>(?=\r?$)';
       Replacement = $r10.TrimEnd() },
    @{ Pattern = '(?m)^        const std::string platformPrefix = fmt::format\(';
       Replacement = $r7.TrimEnd() },
    @{ Pattern = '(?m)^    auto nativeMod = std::make_unique<NativeMod>\(\);(?=\r?$)';
       Replacement = $r8.TrimEnd() },
    @{ Pattern = '(?m)^    nativeMod->meta = nativeMod->handle->LookupSymbol<const ModMeta\*>\("mod_meta"\);(?=\r?$)';
       Replacement = $r9.TrimEnd() }
)

# --- hook.cpp: say what a failed funchook target looks like --------------------------------------
$hookDecl = @'
#include <vector>

// dusk_xbox_modtrace (platforms/xbox/Apply-Patches-ModTrace.ps1): defined at the end of this file
static std::string dusk_xbox_hook_diag(const void* fnAddr);
'@
$hookWarn = @'
            prep, inst, message != nullptr && message[0] != '\0' ? message : "no details");
        DuskLog.warn("HookSystem: [diag] {:p}: {}", fnAddr, dusk_xbox_hook_diag(fnAddr));
'@
$hookDef = @'
}  // namespace dusk::mods::svc

// dusk_xbox_modtrace: module, RVA and first bytes of a function funchook could not hook.
#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
static std::string dusk_xbox_hook_diag(const void* fnAddr) {
    MEMORY_BASIC_INFORMATION mbi{};
    if (VirtualQuery(fnAddr, &mbi, sizeof(mbi)) == 0) {
        return "VirtualQuery failed";
    }
    const auto base = reinterpret_cast<std::uintptr_t>(mbi.AllocationBase);
    const auto addr = reinterpret_cast<std::uintptr_t>(fnAddr);
    const auto regionEnd = reinterpret_cast<std::uintptr_t>(mbi.BaseAddress) + mbi.RegionSize;
    const bool inExe = mbi.AllocationBase == static_cast<const void*>(GetModuleHandleW(nullptr));
    std::string out = fmt::format("{} base={:#x} rva={:#x} protect={:#x} bytes:",
        inExe ? "dusklight.exe" : "other-module", base, addr - base, static_cast<unsigned>(mbi.Protect));
    const auto* p = static_cast<const unsigned char*>(fnAddr);
    for (std::uintptr_t i = 0; i < 24 && addr + i < regionEnd; ++i) {
        out += fmt::format(" {:02x}", p[i]);
    }
    return out;
}
#else
static std::string dusk_xbox_hook_diag(const void*) {
    return {};
}
#endif
'@
if ($script:failed -eq $false) {
    $rel = 'src/dusk/mods/svc/hook.cpp'
    $path = Join-Path $RepoRoot $rel
    if (-not (Test-Path $path)) {
        Write-Host "::error::patch target missing: $rel"
        $script:failed = $true
    } else {
        $text = [System.IO.File]::ReadAllText($path)
        if ($text.Contains($marker)) {
            Write-Host "already patched: $rel"
        } else {
            $pats = @(
                @{ P = '(?m)^#include <vector>(?=\r?$)'; R = $hookDecl.TrimEnd() },
                @{ P = '(?m)^            prep, inst, message != nullptr && message\[0\] != ''\\0'' \? message : "no details"\);(?=\r?$)'; R = $hookWarn.TrimEnd() },
                @{ P = '(?m)^\}  // namespace dusk::mods::svc(?=\r?$)'; R = $hookDef.TrimEnd() }
            )
            $ok = $true
            foreach ($e in $pats) {
                $count = [regex]::Matches($text, $e.P).Count
                if ($count -ne 1) {
                    Write-Host "::error::patch anchor '$($e.P)' in $rel matched $count time(s), expected 1 (upstream changed?)"
                    $ok = $false
                }
            }
            if ($ok) {
                foreach ($e in $pats) {
                    $text = [regex]::Replace($text, $e.P, $e.R.Replace('$', '$$'))
                }
                [System.IO.File]::WriteAllText($path, $text, $utf8)
                Write-Host "patched: $rel (3 edit(s))"
            } else {
                $script:failed = $true
            }
        }
    }
}

if ($script:failed) { exit 1 }
exit 0
