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
  All lines start with "[trace]". The last [trace] line of a crashing launch is the step that never returned.
  Only logging; nothing else changes.

  Idempotent (marker dusk_xbox_modtrace per file). Exits 1 when an anchor does not match exactly once.
  Both files must be listed in $alwaysFresh of Cache-Mtimes.ps1.
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
    Log.info("[trace] opening package {}", data::abbreviated_path_string(modPath));
    if (bundle == nullptr) {
'@
$r1 = @'
    Log.info("[trace] reading mod.json of {}", data::abbreviated_path_string(modPath));
    LoadedManifest manifest;
'@
$r2 = @'
    log::write(mod.metadata.id, LOG_LEVEL_INFO, "[trace] checking for native code");
    if (load_native_if_present(mod) && mod.native) {
'@
$r3 = @'
        log::write(mod.metadata.id, LOG_LEVEL_INFO, "[trace] resolving hooks");
        svc::hook_resolve_mod_records(mod);
'@
$r4 = @'
    const char* initializeName = mod.native ? "mod_initialize" : "runtime activate";
    log::write(mod.metadata.id, LOG_LEVEL_INFO, "[trace] calling {}", initializeName);
'@
$r5 = @'
    Log.info("[trace] init: clearing the native cache {}", data::abbreviated_path_string(m_cacheDir));
    // Stale libs from previous sessions (see load_native).
'@
$r6 = @'
    Log.info("[trace] init: scanning mod packages");
    const auto packages = scan_packages(m_searchDirs);
    Log.info("[trace] init: {} package(s) found", packages.size());
'@
$r7 = @'
        // dusk_xbox_modtrace (platforms/xbox/Apply-Patches-ModTrace.ps1)
        log::write(mod.metadata.id, LOG_LEVEL_INFO, "[trace] extracting native runtime files to {}",
            data::abbreviated_path_string(runtimeDir));
        const std::string platformPrefix = fmt::format(
'@
$r8 = @'
    log::write(mod.metadata.id, LOG_LEVEL_INFO, "[trace] loading native library {}",
        data::abbreviated_path_string(libPath));
    auto nativeMod = std::make_unique<NativeMod>();
'@
$r9 = @'
    log::write(mod.metadata.id, LOG_LEVEL_INFO, "[trace] native library loaded, looking up exports");
    nativeMod->meta = nativeMod->handle->LookupSymbol<const ModMeta*>("mod_meta");
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
       Replacement = $r6.TrimEnd() }
)

# --- natives.cpp ---------------------------------------------------------------------------------
Patch-Trace 'src/dusk/mods/loader/natives.cpp' @(
    @{ Pattern = '(?m)^        const std::string platformPrefix = fmt::format\(';
       Replacement = $r7.TrimEnd() },
    @{ Pattern = '(?m)^    auto nativeMod = std::make_unique<NativeMod>\(\);(?=\r?$)';
       Replacement = $r8.TrimEnd() },
    @{ Pattern = '(?m)^    nativeMod->meta = nativeMod->handle->LookupSymbol<const ModMeta\*>\("mod_meta"\);(?=\r?$)';
       Replacement = $r9.TrimEnd() }
)

if ($script:failed) { exit 1 }
exit 0
