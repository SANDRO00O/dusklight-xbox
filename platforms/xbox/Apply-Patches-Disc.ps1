<#
.SYNOPSIS
  Source patches that let the game read the disc image from a USB drive on the Xbox (UWP).
  Run by ci.ps1 right after `Apply-Patches.ps1 -Phase Source`.

  FOUND ON HARDWARE (builds 97e2887f, deb17009): the FileOpenPicker returns 'E:\...\game.iso' for a file
  on a USB drive, but opening that path fails with ERROR_ACCESS_DENIED. The app only has access through
  the StorageFile, so platforms/xbox/xbox_file_picker.cpp turns it into a HANDLE and exposes
    SDL_IOStream* dusk_xbox_open_disc_stream(const char* utf8Path)   (nullptr = not such a file)
    bool           dusk_xbox_is_picked_path(const char* utf8Path)
  The disc is opened in two places, both through SDL_IOFromFile, and both get the hook here:
    * extern/aurora/lib/dolphin/dvd/dvd.cpp  aurora_dvd_open()  (the game reads the disc through this)
    * extern/borealis/src/io.cpp             io::open()         (disc verification / inspection)
  plus io.cpp's filesystem_check(), which uses std::filesystem::exists (also access denied) and made
  io::check report the picked file as missing.

  Separate from Apply-Patches.ps1 because that script treats any file containing DUSK_XBOX_UWP as
  already patched (io.cpp already has the CreateFileW shim). This one uses its own marker.
  Idempotent; exits 1 when an anchor does not match exactly as often as expected.

  Every file patched here must be listed in $alwaysFresh of Cache-Mtimes.ps1.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$script:failed = $false
$utf8 = New-Object System.Text.UTF8Encoding($false)
$marker = 'dusk_xbox_open_disc_stream'

function Patch-Disc([string]$Rel, [object[]]$Edits) {
    $path = Join-Path $RepoRoot $Rel
    if (-not (Test-Path $path)) {
        Write-Host "::error::patch target missing: $Rel (is the submodule checked out?)"
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
        $text = [regex]::Replace($text, $e.Pattern, $e.Replacement)
    }
    [System.IO.File]::WriteAllText($path, $text, $utf8)
    Write-Host "patched: $Rel ($($Edits.Count) edit(s))"
}

# --- aurora: lib/dolphin/dvd/dvd.cpp -----------------------------------------------------------
$dvdDecl = @'
using namespace aurora::dvd::impl;

#ifdef DUSK_XBOX_UWP
// dusk_xbox_open_disc_stream: platforms/xbox/xbox_file_picker.cpp (see Apply-Patches-Disc.ps1).
extern "C" SDL_IOStream* dusk_xbox_open_disc_stream(const char* utf8Path);
#endif
'@
$dvdOpen = @'
#ifdef DUSK_XBOX_UWP
  // The picked disc on a USB drive is only reachable through its StorageFile.
  SDL_IOStream* io = dusk_xbox_open_disc_stream(disc_path);
  if (io == nullptr) {
    io = SDL_IOFromFile(disc_path, "rb");
  }
#else
  SDL_IOStream* io = SDL_IOFromFile(disc_path, "rb");
#endif
'@
$dvdEdits = @(
    @{ Pattern = '(?m)^using namespace aurora::dvd::impl;(?=\r?$)'; Replacement = $dvdDecl.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^  SDL_IOStream\* io = SDL_IOFromFile\(disc_path, "rb"\);(?=\r?$)'; Replacement = $dvdOpen.TrimEnd(); Expected = 1 }
)
Patch-Disc 'extern/aurora/lib/dolphin/dvd/dvd.cpp' $dvdEdits

# --- borealis: src/io.cpp ----------------------------------------------------------------------
$ioDecl = @'
#ifdef DUSK_XBOX_UWP
// platforms/xbox/xbox_file_picker.cpp (see Apply-Patches-Disc.ps1). dusk_xbox_open_disc_stream returns
// nullptr for every file that is not the picked disc, so callers fall back to SDL_IOFromFile.
extern "C" SDL_IOStream* dusk_xbox_open_disc_stream(const char* utf8Path);
extern "C" bool dusk_xbox_is_picked_path(const char* utf8Path);
#endif

namespace borealis::io {
'@
$ioOpen = @'
#ifdef DUSK_XBOX_UWP
    SDL_IOStream* handle =
        mode == File::Mode::Read ? dusk_xbox_open_disc_stream(resolved.c_str()) : nullptr;
    if (handle == nullptr) {
        handle = SDL_IOFromFile(resolved.c_str(), openMode);
    }
#else
    SDL_IOStream* handle = SDL_IOFromFile(resolved.c_str(), openMode);
#endif
'@
$ioExists = @'
    bool exists = std::filesystem::exists(fs_path_from_utf8(location), error);
#ifdef DUSK_XBOX_UWP
    if (!exists && dusk_xbox_is_picked_path(std::string{location}.c_str())) {
        error.clear();
        exists = true;
    }
#endif
'@
$ioEdits = @(
    @{ Pattern = '(?m)^namespace borealis::io \{(?=\r?$)'; Replacement = $ioDecl.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^    SDL_IOStream\* handle = SDL_IOFromFile\(resolved\.c_str\(\), openMode\);(?=\r?$)'; Replacement = $ioOpen.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^    const bool exists = std::filesystem::exists\(fs_path_from_utf8\(location\), error\);(?=\r?$)'; Replacement = $ioExists.TrimEnd(); Expected = 1 }
)
Patch-Disc 'extern/borealis/src/io.cpp' $ioEdits

# --- SDL3-uwp clone: SDL_Thread::threadid (hang in SDL_OpenAudioDevice, see Apply-Patches-Sdl.ps1) ---
# Kept here so ci.ps1 does not need another call; the clone (build/ext/SDL3-uwp) is fetched before this runs.
& (Join-Path $PSScriptRoot 'Apply-Patches-Sdl.ps1') -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { $script:failed = $true }

# --- aurora: lib/webgpu/gpu.cpp, Dawn toggle disable_resource_suballocation (CreatePlacedResource crash) ---
& (Join-Path $PSScriptRoot 'Apply-Patches-Gpu.ps1') -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { $script:failed = $true }

# --- CPU work reduction from 999sian/dusklight: aurora pipeline queue promote, game matrix recording maps ---
& (Join-Path $PSScriptRoot 'Apply-Patches-Cpu.ps1') -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { $script:failed = $true }

# --- aurora: lib/dolphin/card.cpp, memory card creation logging + fallback ("no slot") ---
& (Join-Path $PSScriptRoot 'Apply-Patches-Card.ps1') -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { $script:failed = $true }

# --- game: water refraction off by default + switch in the settings UI (30 fps in Ordon Village) ---
& (Join-Path $PSScriptRoot 'Apply-Patches-Water.ps1') -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { $script:failed = $true }

# --- UI stylesheets: no backdrop blur / blurred shadows (fps drops on the mods page); best effort ---
& (Join-Path $PSScriptRoot 'Apply-Patches-Ui.ps1') -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { $script:failed = $true }

# --- bundled pipeline list (initial_pipeline_cache.db) staged for the package; best effort ---
& (Join-Path $PSScriptRoot 'Fetch-PipelineSeed.ps1') -RepoRoot $RepoRoot

# --- aurora: lib/gfx/pipeline_cache.cpp, warmup order / low priority background compile / build timing ---
& (Join-Path $PSScriptRoot 'Apply-Patches-Shaders.ps1') -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { $script:failed = $true }

# --- aurora: lib/gfx/pipeline_cache.cpp, second compile thread for the GX warmup (needs the patch above) ---
& (Join-Path $PSScriptRoot 'Apply-Patches-Shaders2.ps1') -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { $script:failed = $true }

# --- game: optional title-scene override via title-scene.txt (EXPERIMENTAL, no effect without that file) ---
& (Join-Path $PSScriptRoot 'Apply-Patches-Title.ps1') -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { $script:failed = $true }

# --- mod install: weakly_canonical / fs::relative fail with "Access denied" in the Xbox sandbox (loader.cpp, bundle_disk.cpp) ---
& (Join-Path $PSScriptRoot 'Apply-Patches-ModInstall.ps1') -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { $script:failed = $true }

# --- native mods: when mod.dll fails to load, log which imports are unresolved (native_module.cpp) ---
& (Join-Path $PSScriptRoot 'Apply-Patches-NativeDiag.ps1') -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { $script:failed = $true }

# --- native mods: export wgpu* from the exe with a static Dawn (mod.dll imports them, error 127; cmake/WindowsExports.cmake) ---
& (Join-Path $PSScriptRoot 'Apply-Patches-ModExports.ps1') -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { $script:failed = $true }

# --- native mods: [trace +ms] log lines before each loader step + [diag] for failed funchook targets (loader.cpp, natives.cpp, hook.cpp) ---
& (Join-Path $PSScriptRoot 'Apply-Patches-ModTrace.ps1') -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { $script:failed = $true }

# --- frame stage timers in aurora_end_frame, logged only while the main thread is slow (aurora.cpp) ---
& (Join-Path $PSScriptRoot 'Apply-Patches-FrameTimers.ps1') -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { $script:failed = $true }

if ($script:failed) { exit 1 }
exit 0
