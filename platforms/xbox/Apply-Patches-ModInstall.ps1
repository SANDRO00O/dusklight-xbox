<#
.SYNOPSIS
  Mod install on the Xbox (UWP): "Could not resolve the user mods directory: Access denied".
  Called by Apply-Patches-Disc.ps1 from ci.ps1 before configure.

  FOUND ON HARDWARE: a mod downloads and verifies fine (.downloads -> .staging), then the install step
  fails. ModLoader::install_staged (src/dusk/mods/loader/loader.cpp) starts with
  std::filesystem::weakly_canonical(<mods dir>), which the Xbox UWP sandbox rejects with "Access denied".
  The same call family (fs::relative) is what made directory-backed mods exit the app at startup in the
  fork 999sian/dusklight; it fixed that one with lexically_relative (bundle_disk.cpp, "avoid physical-path
  resolution on Xbox") and left its browser install error unresolved.

  1. loader.cpp: every fs::weakly_canonical(...) goes through dusk_resolve_path(), which is lexical on UWP
     (absolute + lexically_normal). The staging containment check only compares the staged file's parent
     with <mods dir>/.staging, both built from the same base path, so a lexical comparison is equivalent.
  2. bundle_disk.cpp: fs::relative(path, root_path) -> path.lexically_relative(root_path) on UWP.

  Idempotent (marker dusk_xbox_modinstall). Exits 1 when an anchor does not match exactly as often as
  expected. Both patched files must be listed in $alwaysFresh of Cache-Mtimes.ps1.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$script:failed = $false
$utf8 = New-Object System.Text.UTF8Encoding($false)
$marker = 'dusk_xbox_modinstall'

function Patch-ModInstall([string]$Rel, [object[]]$Edits) {
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
        if ($count -ne $e.Expected) {
            Write-Host "::error::patch anchor '$($e.Pattern)' in $Rel matched $count time(s), expected $($e.Expected) (upstream changed?)"
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

# --- 1. loader.cpp: weakly_canonical -> lexical on UWP -----------------------------------------------
# Order matters: the call sites are replaced first, then the helper (which itself contains the real
# fs::weakly_canonical call for non-UWP builds) is inserted.
$resolveHelper = @'
// dusk_xbox_modinstall: std::filesystem::weakly_canonical asks the file system for the final path name,
// which the Xbox (UWP) sandbox answers with "Access denied". Resolve lexically there
// (see Apply-Patches-ModInstall.ps1).
fs::path dusk_resolve_path(const fs::path& path, std::error_code& error) {
#ifdef DUSK_XBOX_UWP
    error.clear();
    const auto absolute = fs::absolute(path, error);
    return error ? fs::path{} : absolute.lexically_normal();
#else
    return fs::weakly_canonical(path, error);
#endif
}

LoadedMod::FileIdentity file_identity(const fs::path& path) {
'@
Patch-ModInstall 'src/dusk/mods/loader/loader.cpp' @(
    @{ Pattern = 'fs::weakly_canonical\(';
       Replacement = 'dusk_resolve_path('; Expected = 4 },
    @{ Pattern = '(?m)^LoadedMod::FileIdentity file_identity\(const fs::path& path\) \{(?=\r?$)';
       Replacement = $resolveHelper.TrimEnd(); Expected = 1 }
)

# --- 2. bundle_disk.cpp: fs::relative -> lexically_relative on UWP ------------------------------------
$relNew = @'
#ifdef DUSK_XBOX_UWP
        // dusk_xbox_modinstall: fs::relative resolves physical paths (Access denied on the Xbox); the
        // iterator's paths already start with root_path, so the lexical result is the same.
        const auto relPath = path.lexically_relative(root_path);
#else
        const auto relPath = fs::relative(path, root_path);
#endif
'@
Patch-ModInstall 'src/dusk/mods/loader/bundle_disk.cpp' @(
    @{ Pattern = '(?m)^        const auto relPath = fs::relative\(path, root_path\);(?=\r?$)';
       Replacement = $relNew.TrimEnd(); Expected = 1 }
)

if ($script:failed) { exit 1 }
exit 0
