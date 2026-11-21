<#
.SYNOPSIS
  Diagnostic for native (code) mods that fail to load on the Xbox (UWP). Called by Apply-Patches-Disc.ps1.

  FOUND ON HARDWARE (dusklight log of 2026-11-22): mod.dll of Deferred Fog, Cinematic Depth of Field and
  Evil Interlacing fail with "The specified procedure could not be found" (error 127). Windows reports no
  name, so the log cannot tell which import is missing: a function the dusklight.exe export list does not
  contain (the mod was built against another game revision), or a desktop-only API of a system DLL that the
  console does not have.

  src/dusk/mods/loader/native_module.cpp: when LoadLibraryExW fails, the PE import table of the DLL is
  read from the file and every import is resolved with GetModuleHandle / LoadLibraryEx + GetProcAddress. The
  unresolved ones ("dll!function", at most 25 of the first ones found, plus the total) are appended to the
  error message, which the mod loader writes to the log as
  "failed to open <path>/mod.dll: The specified procedure could not be found. | N unresolved import(s): ...".
  Only runs after a failure; nothing changes when the DLL loads.

  Idempotent (marker dusk_xbox_importdiag). Exits 1 when an anchor does not match exactly once.
  The patched file must be listed in $alwaysFresh of Cache-Mtimes.ps1.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$script:failed = $false
$utf8 = New-Object System.Text.UTF8Encoding($false)
$marker = 'dusk_xbox_importdiag'

function Patch-Diag([string]$Rel, [object[]]$Edits) {
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

$includes = @'
#include <Windows.h>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>
'@

$helper = @'
// dusk_xbox_importdiag: why does LoadLibrary say "procedure not found"? Lists the imports of the DLL that
// no loaded module provides (see platforms/xbox/Apply-Patches-NativeDiag.ps1). Best effort, never throws.
std::string dusk_diagnose_imports(const std::filesystem::path& path) {
    try {
        std::ifstream in(path, std::ios::binary);
        if (!in) {
            return {};
        }
        const std::vector<char> data((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        const auto* base = reinterpret_cast<const unsigned char*>(data.data());
        if (data.size() < sizeof(IMAGE_DOS_HEADER)) {
            return {};
        }
        const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
        if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0 ||
            static_cast<size_t>(dos->e_lfanew) + sizeof(IMAGE_NT_HEADERS64) > data.size()) {
            return {};
        }
        const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
        if (nt->Signature != IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) {
            return {};
        }
        const auto* sections = IMAGE_FIRST_SECTION(nt);
        const unsigned sectionCount = nt->FileHeader.NumberOfSections;
        auto toOffset = [&](DWORD rva) -> size_t {
            if (rva < nt->OptionalHeader.SizeOfHeaders) {
                return rva;
            }
            for (unsigned i = 0; i < sectionCount; ++i) {
                const DWORD size = std::max<DWORD>(sections[i].Misc.VirtualSize, sections[i].SizeOfRawData);
                if (rva >= sections[i].VirtualAddress && rva < sections[i].VirtualAddress + size) {
                    return static_cast<size_t>(sections[i].PointerToRawData) + (rva - sections[i].VirtualAddress);
                }
            }
            return SIZE_MAX;
        };
        auto readString = [&](DWORD rva) -> std::string {
            const size_t offset = toOffset(rva);
            if (offset >= data.size()) {
                return {};
            }
            const char* text = data.data() + offset;
            return std::string(text, strnlen(text, data.size() - offset));
        };
        const auto& importDir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
        if (importDir.VirtualAddress == 0) {
            return {};
        }
        std::vector<std::string> missing;
        size_t total = 0;
        size_t d = toOffset(importDir.VirtualAddress);
        for (; d != SIZE_MAX && d + sizeof(IMAGE_IMPORT_DESCRIPTOR) <= data.size(); d += sizeof(IMAGE_IMPORT_DESCRIPTOR)) {
            const auto* desc = reinterpret_cast<const IMAGE_IMPORT_DESCRIPTOR*>(base + d);
            if (desc->Name == 0) {
                break;
            }
            const std::string dllName = readString(desc->Name);
            const std::wstring wideName(dllName.begin(), dllName.end());
            HMODULE module = GetModuleHandleW(wideName.c_str());
            if (module == nullptr) {
                module = LoadLibraryExW(wideName.c_str(), nullptr,
                    LOAD_LIBRARY_SEARCH_DEFAULT_DIRS | LOAD_LIBRARY_SEARCH_APPLICATION_DIR);
            }
            if (module == nullptr) {
                ++total;
                if (missing.size() < 25) {
                    missing.push_back(dllName + " (module cannot be loaded)");
                }
                continue;
            }
            size_t t = toOffset(desc->OriginalFirstThunk != 0 ? desc->OriginalFirstThunk : desc->FirstThunk);
            for (; t != SIZE_MAX && t + sizeof(ULONGLONG) <= data.size(); t += sizeof(ULONGLONG)) {
                ULONGLONG entry = 0;
                std::memcpy(&entry, base + t, sizeof(entry));
                if (entry == 0) {
                    break;
                }
                FARPROC proc = nullptr;
                std::string label;
                if ((entry & IMAGE_ORDINAL_FLAG64) != 0) {
                    const WORD ordinal = static_cast<WORD>(entry & 0xFFFF);
                    label = "#" + std::to_string(ordinal);
                    proc = GetProcAddress(module, MAKEINTRESOURCEA(ordinal));
                } else {
                    label = readString(static_cast<DWORD>(entry) + 2);
                    proc = GetProcAddress(module, label.c_str());
                }
                if (proc == nullptr) {
                    ++total;
                    if (missing.size() < 25) {
                        missing.push_back(dllName + "!" + label);
                    }
                }
            }
        }
        if (total == 0) {
            return " | import check: every import resolves, so the failure is inside the DLL (static initialisation / DllMain)";
        }
        std::string result = " | " + std::to_string(total) + " unresolved import(s): ";
        for (size_t i = 0; i < missing.size(); ++i) {
            result += (i == 0 ? "" : ", ") + missing[i];
        }
        return result;
    } catch (...) {
        return {};
    }
}

void* pl_dlopen(const std::filesystem::path& p) {
'@

$throwNew = @'
        const std::string baseError = pl_dlerror();
#if defined(_WIN32)
        throw std::runtime_error(baseError + dusk_diagnose_imports(path));
#else
        throw std::runtime_error(baseError);
#endif
'@

Patch-Diag 'src/dusk/mods/loader/native_module.cpp' @(
    @{ Pattern = '(?m)^#include <Windows\.h>(?=\r?$)';
       Replacement = $includes.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^void\* pl_dlopen\(const std::filesystem::path& p\) \{(?=\r?\n    return LoadLibraryExW)';
       Replacement = $helper.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^        throw std::runtime_error\(pl_dlerror\(\)\);(?=\r?$)';
       Replacement = $throwNew.TrimEnd(); Expected = 1 }
)

if ($script:failed) { exit 1 }
exit 0
