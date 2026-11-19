// Feasibility probe for native ("code") mods on the Xbox (UWP). Part of the Xbox port.
//
// QUESTION: native mods are DLLs the game loads at run time and that patch game code in memory (funchook).
// UWP normally forbids both. The codeGeneration capability (declared in the manifest by Patch-Manifest.ps1)
// is documented to allow executable memory through VirtualProtectFromApp / CreateFileMappingFromApp /
// MapViewOfFileFromApp, but never both writable and executable at once (W^X). Whether that works on THIS
// console (Xbox One S, Dev Mode, app running as "Game") is not documented, so this file measures it and
// writes <LocalState>\TwilitRealm\Dusklight\jit-probe.log. It decides whether a manual PE loader + a W^X
// port of funchook is worth writing.
//
// Safety: it runs once (state file jit-probe.state: "running" while the risky steps execute, "v1-done"
// afterwards). If a step crashes the process, the next start sees "running", logs that and does not try
// again. It starts on a background thread ~10 s after launch, runs nothing from mods and changes no game
// state. Everything that may be missing on UWP is looked up with GetProcAddress, never linked.

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>

#if __has_include(<winrt/Windows.Storage.h>) && __has_include(<winrt/Windows.System.h>)
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.System.h>
#define DUSK_JIT_PROBE_WINRT 1
#else
#define DUSK_JIT_PROBE_WINRT 0
#endif

namespace {

constexpr const char* kStateDone = "v1-done";

FILE* g_log = nullptr;

void Out(const char* fmt, ...) {
    if (g_log == nullptr) {
        return;
    }
    char buf[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    fprintf(g_log, "%s\n", buf);
    fflush(g_log);
}

using VirtualAllocFromAppFn = PVOID(WINAPI*)(PVOID, SIZE_T, ULONG, ULONG);
using VirtualProtectFromAppFn = BOOL(WINAPI*)(PVOID, SIZE_T, ULONG, PULONG);
using CreateFileMappingFromAppFn = HANDLE(WINAPI*)(HANDLE, PSECURITY_ATTRIBUTES, ULONG, ULONG64, PCWSTR);
using MapViewOfFileFromAppFn = PVOID(WINAPI*)(HANDLE, ULONG, ULONG64, SIZE_T);
using LoadLibraryExWFn = HMODULE(WINAPI*)(LPCWSTR, HANDLE, DWORD);
using RtlAddFunctionTableFn = BOOLEAN(WINAPI*)(PRUNTIME_FUNCTION, DWORD, DWORD64);

FARPROC Find(const char* name) {
    static const wchar_t* modules[] = {L"kernelbase.dll", L"kernel32.dll", L"ntdll.dll"};
    for (const wchar_t* module : modules) {
        if (HMODULE handle = GetModuleHandleW(module)) {
            if (FARPROC fn = GetProcAddress(handle, name)) {
                return fn;
            }
        }
    }
    return nullptr;
}

// `mov eax, 42 ; ret`
const unsigned char kCode[] = {0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3};

// No C++ objects here: __try must not be mixed with unwinding.
int CallCode(void* code, int* faulted) {
    *faulted = 0;
    __try {
        return reinterpret_cast<int (*)()>(code)();
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        *faulted = static_cast<int>(GetExceptionCode());
        return -1;
    }
}

// A function in the game's own image (stand-in for the code funchook patches). It lives in a section of its
// own, so its page holds no other game code: switching that page to RW while the game's threads run would
// crash them.
#pragma code_seg(push, ".jprobe")
__declspec(noinline) int ImageTarget(int value) {
    return value * 3 + 1;
}
#pragma code_seg(pop)

void Report(const char* what, bool ok) {
    Out("  %-58s %s (GetLastError=%lu)", what, ok ? "OK" : "FAILED", ok ? 0ul : GetLastError());
}

void ProbeExecutableMemory() {
    auto allocFromApp = reinterpret_cast<VirtualAllocFromAppFn>(Find("VirtualAllocFromApp"));
    auto protectFromApp = reinterpret_cast<VirtualProtectFromAppFn>(Find("VirtualProtectFromApp"));
    auto createMapping = reinterpret_cast<CreateFileMappingFromAppFn>(Find("CreateFileMappingFromApp"));
    auto mapView = reinterpret_cast<MapViewOfFileFromAppFn>(Find("MapViewOfFileFromApp"));
    Out("[1] entry points: VirtualAllocFromApp=%d VirtualProtectFromApp=%d CreateFileMappingFromApp=%d "
        "MapViewOfFileFromApp=%d",
        allocFromApp != nullptr, protectFromApp != nullptr, createMapping != nullptr, mapView != nullptr);

    // --- A: private memory, RW -> RX ---
    if (allocFromApp && protectFromApp) {
        Out("[2] private memory: allocate RW, write code, switch to RX, run");
        void* page = allocFromApp(nullptr, 0x10000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        Report("VirtualAllocFromApp(RW)", page != nullptr);
        if (page != nullptr) {
            std::memcpy(page, kCode, sizeof(kCode));
            ULONG old = 0;
            const bool rx = protectFromApp(page, 0x10000, PAGE_EXECUTE_READ, &old) != FALSE;
            Report("VirtualProtectFromApp(RX)", rx);
            if (rx) {
                FlushInstructionCache(GetCurrentProcess(), page, sizeof(kCode));
                int faulted = 0;
                const int value = CallCode(page, &faulted);
                Out("  run generated code: result=%d fault=0x%08x %s", value, faulted,
                    value == 42 ? "OK" : "FAILED");
                // W^X toggle: back to RW, patch, back to RX, run again.
                const bool rw = protectFromApp(page, 0x10000, PAGE_READWRITE, &old) != FALSE;
                Report("VirtualProtectFromApp(RX -> RW)", rw);
                if (rw) {
                    static_cast<unsigned char*>(page)[1] = 0x2B;  // mov eax, 43
                    const bool rx2 = protectFromApp(page, 0x10000, PAGE_EXECUTE_READ, &old) != FALSE;
                    Report("VirtualProtectFromApp(RW -> RX) again", rx2);
                    if (rx2) {
                        FlushInstructionCache(GetCurrentProcess(), page, sizeof(kCode));
                        const int again = CallCode(page, &faulted);
                        Out("  run patched code: result=%d fault=0x%08x %s", again, faulted,
                            again == 43 ? "OK" : "FAILED");
                    }
                }
            }
            const bool rwx = protectFromApp(page, 0x10000, PAGE_EXECUTE_READWRITE, &old) != FALSE;
            Out("  RWX request: %s (documented as refused; funchook asks for RWX)",
                rwx ? "ACCEPTED" : "refused");
        }
    }

    // --- B: dual view of one section (one RW view, one RX view) ---
    if (createMapping && mapView) {
        Out("[3] dual mapping: write through a RW view, execute through a RX view of the same pages");
        HANDLE mapping = createMapping(INVALID_HANDLE_VALUE, nullptr, PAGE_EXECUTE_READWRITE, 0x10000, nullptr);
        Report("CreateFileMappingFromApp(EXECUTE_READWRITE)", mapping != nullptr);
        if (mapping != nullptr) {
            void* rwView = mapView(mapping, FILE_MAP_WRITE, 0, 0x10000);
            Report("MapViewOfFileFromApp(WRITE)", rwView != nullptr);
            void* rxView = mapView(mapping, FILE_MAP_READ | FILE_MAP_EXECUTE, 0, 0x10000);
            Report("MapViewOfFileFromApp(READ|EXECUTE)", rxView != nullptr);
            if (rwView && rxView) {
                std::memcpy(rwView, kCode, sizeof(kCode));
                FlushInstructionCache(GetCurrentProcess(), rxView, sizeof(kCode));
                int faulted = 0;
                const int value = CallCode(rxView, &faulted);
                Out("  run code written through the other view: result=%d fault=0x%08x %s", value, faulted,
                    value == 42 ? "OK" : "FAILED");
            }
        }
    }

    // --- C: patch code inside the game's own image (what funchook does to hook a game function) ---
    if (protectFromApp) {
        Out("[4] patching the game image: RX -> RW -> RX on a page of the exe");
        auto* target = reinterpret_cast<unsigned char*>(&ImageTarget);
        void* page = reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(target) & ~static_cast<uintptr_t>(0xFFF));
        ULONG old = 0;
        const bool rw = protectFromApp(page, 0x1000, PAGE_READWRITE, &old) != FALSE;
        Out("  image page was protection 0x%lx", old);
        Report("VirtualProtectFromApp(image page -> RW)", rw);
        if (rw) {
            const unsigned char first = target[0];
            target[0] = first;  // write the byte it already has: proves the page is writable, changes nothing
            ULONG ignore = 0;
            const bool rx = protectFromApp(page, 0x1000, old ? old : PAGE_EXECUTE_READ, &ignore) != FALSE;
            Report("VirtualProtectFromApp(image page -> back)", rx);
            FlushInstructionCache(GetCurrentProcess(), page, 0x1000);
            Out("  game code still runs: ImageTarget(2)=%d %s", ImageTarget(2), ImageTarget(2) == 7 ? "OK" : "FAILED");
        }
    }
}

void ProbeLoader() {
    Out("[5] module loading");
    auto loadLibraryEx = reinterpret_cast<LoadLibraryExWFn>(Find("LoadLibraryExW"));
    Out("  LoadLibraryExW resolvable via GetProcAddress: %d", loadLibraryEx != nullptr);
    Out("  RtlAddFunctionTable (x64 exception data for manually mapped code): %d", Find("RtlAddFunctionTable") != nullptr);
    Out("  RtlInstallFunctionTableCallback: %d", Find("RtlInstallFunctionTableCallback") != nullptr);
    if (loadLibraryEx) {
        // Desktop mods import the desktop C++ runtime; the console only has the _APP framework variants.
        static const wchar_t* names[] = {L"VCRUNTIME140.dll", L"VCRUNTIME140_1.dll", L"MSVCP140.dll",
            L"VCRUNTIME140_APP.dll", L"MSVCP140_APP.dll", L"ucrtbase.dll", L"api-ms-win-crt-runtime-l1-1-0.dll"};
        for (const wchar_t* name : names) {
            HMODULE module = GetModuleHandleW(name);
            const bool already = module != nullptr;
            if (!module) {
                module = loadLibraryEx(name, nullptr, 0);
            }
            Out("  %-38ls loaded=%d%s (GetLastError=%lu)", name, module != nullptr, already ? " (already in process)" : "",
                module ? 0ul : GetLastError());
        }
    }
}

// Does an unsigned image outside the package load? The game's own exe copied to LocalState is a valid
// image without a signature of its own; it is mapped without running any code (DONT_RESOLVE_DLL_REFERENCES).
void ProbeUnsignedImage(const std::wstring& directory) {
    auto loadLibraryEx = reinterpret_cast<LoadLibraryExWFn>(Find("LoadLibraryExW"));
    if (!loadLibraryEx) {
        return;
    }
    Out("[6] unsigned image outside the package (LocalState)");
    wchar_t exePath[MAX_PATH] = {};
    if (GetModuleFileNameW(nullptr, exePath, MAX_PATH) == 0) {
        Out("  GetModuleFileNameW failed (%lu)", GetLastError());
        return;
    }
    WIN32_FILE_ATTRIBUTE_DATA data{};
    if (!GetFileAttributesExW(exePath, GetFileExInfoStandard, &data)) {
        Out("  cannot stat the exe (%lu)", GetLastError());
        return;
    }
    const unsigned long long size = (static_cast<unsigned long long>(data.nFileSizeHigh) << 32) | data.nFileSizeLow;
    if (size > 300ull * 1024 * 1024) {
        Out("  exe is %llu bytes, skipping the copy test", size);
        return;
    }
    const std::wstring copy = directory + L"\\jit-probe-image.dll";
    COPYFILE2_EXTENDED_PARAMETERS params{sizeof(params)};
    const HRESULT copied = CopyFile2(exePath, copy.c_str(), &params);
    Out("  copy of the exe (%llu bytes) to LocalState: hr=0x%08lx", size, static_cast<unsigned long>(copied));
    if (SUCCEEDED(copied)) {
        HMODULE module = loadLibraryEx(copy.c_str(), nullptr, DONT_RESOLVE_DLL_REFERENCES);
        Out("  LoadLibraryExW(unsigned copy in LocalState): %s (GetLastError=%lu)", module ? "LOADED" : "REFUSED",
            module ? 0ul : GetLastError());
        if (module) {
            FreeLibrary(module);
        }
        DeleteFileW(copy.c_str());
    }
}

void RunProbe() {
    Sleep(10000);  // let the app finish activation first

    std::wstring directory;
#if DUSK_JIT_PROBE_WINRT
    try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
    } catch (...) {
    }
    try {
        directory = std::wstring{winrt::Windows::Storage::ApplicationData::Current().LocalFolder().Path()} +
                    L"\\TwilitRealm\\Dusklight";
    } catch (...) {
        return;
    }
#else
    return;
#endif
    CreateDirectoryW((directory.substr(0, directory.find_last_of(L'\\'))).c_str(), nullptr);
    CreateDirectoryW(directory.c_str(), nullptr);

    const std::wstring statePath = directory + L"\\jit-probe.state";
    char state[32] = {};
    if (FILE* in = _wfopen(statePath.c_str(), L"rb")) {
        fread(state, 1, sizeof(state) - 1, in);
        fclose(in);
    }
    g_log = _wfopen((directory + L"\\jit-probe.log").c_str(), L"ab");
    if (g_log == nullptr) {
        return;
    }
    if (std::strcmp(state, kStateDone) == 0) {
        fclose(g_log);
        g_log = nullptr;
        return;  // measured already on this install
    }
    if (std::strcmp(state, "running") == 0) {
        Out("=== previous probe run did not finish (the process died in one of the steps listed above); not repeating ===");
        if (FILE* out = _wfopen(statePath.c_str(), L"wb")) {
            fputs(kStateDone, out);
            fclose(out);
        }
        fclose(g_log);
        g_log = nullptr;
        return;
    }
    if (FILE* out = _wfopen(statePath.c_str(), L"wb")) {
        fputs("running", out);
        fclose(out);
    }

    Out("=== jit-probe v1 ===");
    SYSTEM_INFO info{};
    GetNativeSystemInfo(&info);
    Out("logical processors reported: %lu, page size %lu", info.dwNumberOfProcessors, info.dwPageSize);
#if DUSK_JIT_PROBE_WINRT
    try {
        using winrt::Windows::System::MemoryManager;
        Out("memory budget: AppMemoryUsageLimit=%llu MB, AppMemoryUsage=%llu MB (about 1024 = App mode, about 5000 = Game mode)",
            static_cast<unsigned long long>(MemoryManager::AppMemoryUsageLimit() / (1024 * 1024)),
            static_cast<unsigned long long>(MemoryManager::AppMemoryUsage() / (1024 * 1024)));
    } catch (...) {
        Out("memory budget: Windows.System.MemoryManager unavailable");
    }
#endif
    ProbeExecutableMemory();
    ProbeLoader();
    ProbeUnsignedImage(directory);
    Out("=== done ===");
    fclose(g_log);
    g_log = nullptr;
    if (FILE* out = _wfopen(statePath.c_str(), L"wb")) {
        fputs(kStateDone, out);
        fclose(out);
    }
}

struct Starter {
    Starter() {
        try {
            std::thread(RunProbe).detach();
        } catch (...) {
        }
    }
};
const Starter g_starter;

}  // namespace
