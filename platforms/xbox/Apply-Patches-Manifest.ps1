<#
.SYNOPSIS
  Native mods on the Xbox: let the game read the symbol manifest from a file in the package when the exe has none.
  Called by Apply-Patches-Disc.ps1. Patches src/dusk/mods/manifest.cpp.

  FOUND ON HARDWARE (dusklight log + Assets/mods-build.log of 2026-11-28):
    * the BUILT dusklight.exe has the manifest (".symdbh rva=0x26A8000 size=7,179,709", 46,387,200 bytes),
    * the dusklight.exe INSIDE the .msix has none (rva=0, 39,207,424 bytes = the built one minus the 7 MB section),
    * build.log: the AppxPackage step ("dusklight -> ...\dusklight_1.0.0.0_x64_RelWithDebInfo.msix") runs BEFORE the
      PostBuildEvent that runs "symgen manifest --embed" ("Embedding symbol manifest"), and a second build (the
      repackaging build for the symbol table) still packages the exe without it.
  So the game logs "no symbol manifest embedded" and every by-name hook fails (Deferred Fog, Cinematic Depth of
  Field, Twilight Compass, Twilit Essentials, health bar ...).

  Fix: ci.ps1 copies the manifest blob out of the built exe (the bytes the descriptor points at) into
  <build>/dusklight.symdb, which xbox-project.cmake packages as symbols/dusklight.symdb (the same way as
  symbols/dusklight.sym, a deployment-content file that the repackaging build DOES pick up). This patch makes
  manifest::initialize() use that file when the descriptor in the exe is empty. The blob has its own header with
  the build id (PDB GUID + age) that is checked against the running image as before, so a file from another build
  is rejected ("stale") and not used.

  Idempotent (marker dusk_xbox_symdb_file). Exits 1 when an anchor does not match exactly once.
  src/dusk/mods/manifest.cpp is in $alwaysFresh of Cache-Mtimes.ps1.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$marker = 'dusk_xbox_symdb_file'
$rel = 'src/dusk/mods/manifest.cpp'
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

$r0 = @'
#include <string>

#include <zstd.h>
'@
$r1 = @'
#if defined(_WIN32)
// dusk_xbox_symdb_file (platforms/xbox/Apply-Patches-Manifest.ps1): the manifest blob shipped next to the exe as
// symbols/dusklight.symdb (placeholders are shorter than a header and are ignored).
static std::vector<uint8_t> dusk_xbox_read_symdb_file() {
    std::vector<uint8_t> out;
    wchar_t buf[1024];
    const DWORD n = GetModuleFileNameW(nullptr, buf, 1024);
    if (n == 0 || n >= 1024) {
        return out;
    }
    std::wstring p(buf, n);
    const auto slash = p.find_last_of(L"\\/");
    if (slash == std::wstring::npos) {
        return out;
    }
    p.resize(slash + 1);
    p += L"symbols\\dusklight.symdb";
    CREATEFILE2_EXTENDED_PARAMETERS ep{};
    ep.dwSize = sizeof(ep);
    ep.dwFileAttributes = FILE_ATTRIBUTE_NORMAL;
    HANDLE h = CreateFile2(p.c_str(), GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING, &ep);
    if (h == INVALID_HANDLE_VALUE) {
        return out;
    }
    LARGE_INTEGER size{};
    if (GetFileSizeEx(h, &size) && size.QuadPart >= static_cast<LONGLONG>(sizeof(Header)) &&
        size.QuadPart < (256ll << 20))
    {
        std::vector<uint8_t> data(static_cast<size_t>(size.QuadPart));
        size_t done = 0;
        while (done < data.size()) {
            DWORD got = 0;
            const DWORD want = static_cast<DWORD>(std::min<size_t>(data.size() - done, size_t{1} << 24));
            if (!ReadFile(h, data.data() + done, want, &got, nullptr) || got == 0) {
                break;
            }
            done += got;
        }
        if (done == data.size()) {
            out = std::move(data);
        }
    }
    CloseHandle(h);
    return out;
}
#endif

void initialize() {
'@
$r2 = @'
    // dusk_xbox_symdb_file (platforms/xbox/Apply-Patches-Manifest.ps1)
    static std::vector<uint8_t> s_dskFileBlob;
    if (s_symdbDescriptor.rva == 0) {
#if defined(_WIN32)
        s_dskFileBlob = dusk_xbox_read_symdb_file();
#endif
        if (s_dskFileBlob.empty()) {
            Log.info("no symbol manifest embedded; by-name resolution unavailable");
            return;
        }
        Log.info("symbol manifest read from symbols/dusklight.symdb ({} bytes)", s_dskFileBlob.size());
    }
'@
$r3 = @'
    const auto* blob = !s_dskFileBlob.empty()
        ? s_dskFileBlob.data()
        : reinterpret_cast<const uint8_t*>(imageBase + s_symdbDescriptor.rva);
'@
$r4 = @'
    const auto blobLen = !s_dskFileBlob.empty() ? s_dskFileBlob.size()
                                                : static_cast<size_t>(s_symdbDescriptor.size);
'@

$edits = @(
    @{ P = '(?m)^#include <zstd\.h>(?=\r?$)'; R = $r0.TrimEnd() },
    @{ P = '(?m)^void initialize\(\) \{(?=\r?$)'; R = $r1.TrimEnd() },
    @{ P = '(?m)^    if \(s_symdbDescriptor\.rva == 0\) \{\r?\n        Log\.info\("no symbol manifest embedded; by-name resolution unavailable"\);\r?\n        return;\r?\n    \}(?=\r?$)'; R = $r2.TrimEnd() },
    @{ P = '(?m)^    const auto\* blob = reinterpret_cast<const uint8_t\*>\(imageBase \+ s_symdbDescriptor\.rva\);(?=\r?$)'; R = $r3.TrimEnd() },
    @{ P = '(?m)^    const auto blobLen = static_cast<size_t>\(s_symdbDescriptor\.size\);(?=\r?$)'; R = $r4.TrimEnd() }
)
$ok = $true
foreach ($e in $edits) {
    $count = [regex]::Matches($text, $e.P).Count
    if ($count -ne 1) {
        Write-Host "::error::patch anchor '$($e.P)' in $rel matched $count time(s), expected 1 (upstream changed?)"
        $ok = $false
    }
}
if (-not $ok) { exit 1 }
foreach ($e in $edits) {
    $text = [regex]::Replace($text, $e.P, $e.R.Replace('$', '$$'))
}
[System.IO.File]::WriteAllText($path, $text, $utf8)
Write-Host "patched: $rel ($($edits.Count) edit(s), symbol manifest from symbols/dusklight.symdb)"
exit 0
