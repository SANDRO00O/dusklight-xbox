// Xbox One (UWP) crash + hang diagnostics. Part of the Xbox port, see docs/xbox-port.md.
//
// Why: after the disc image became readable (build 7c59522e) the game starts, runs two frames of the logo
// scene and then the log goes silent with a black screen, and borealis' crash handler (an unhandled-exception
// filter) prints nothing. So it is either a hang or a failure that bypasses that filter, and the only
// feedback channel is the log files. This writes <CachePath>/crash-diag.log with:
//   * a vectored exception handler: every access violation / illegal instruction / breakpoint / heap
//     corruption / ... (first chance, so also the ones the program handles itself) with a stack trace;
//   * hooks for abort(), std::terminate and invalid CRT parameters (they end in a fast-fail that no exception
//     handler sees) that log the calling thread's stack;
//   * a watchdog that logs the disc read statistics (xbox_file_picker.cpp) and, shortly after the game starts
//     reading the disc, dumps the stack of EVERY thread of the process a few times. A hung game shows up as
//     threads parked in the same place in consecutive dumps.
// Function names come from symbols/dusklight.sym (generated from the linker map by Make-Symbols.ps1 in CI and
// packaged in the msix); without it the frames show module + rva only.
// The code only observes; it never changes behaviour. APIs whose availability in the UWP partition is not
// certain are resolved with GetProcAddress at run time so they cannot break the build.
//
// Entry point (called from dusk_xbox_input_diag_start, i.e. right before aurora_initialize, on the game thread):
//   void dusk_xbox_crash_diag_start(const wchar_t* dir);

#include <windows.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <string>
#include <thread>
#include <vector>

extern "C" void dusk_xbox_disc_stats(unsigned long long* out);

namespace {

std::atomic_bool g_started{false};
FILE* g_file = nullptr;
std::atomic<size_t> g_bytes{0};
constexpr size_t kMaxBytes = 6u * 1024u * 1024u;
DWORD g_mainTid = 0;
uintptr_t g_exeBase = 0;

// One formatted write per line; the CRT's own (recursive) FILE lock makes this safe from any thread,
// including an exception handler running on a thread that is in the middle of a write.
void Out(const char* fmt, ...) {
    FILE* f = g_file;
    if (f == nullptr || g_bytes.load() > kMaxBytes) {
        return;
    }
    char buf[1024];
    int n = snprintf(buf, sizeof(buf) - 2, "[%8llu ms] ", static_cast<unsigned long long>(GetTickCount64()));
    if (n < 0) {
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    int m = vsnprintf(buf + n, sizeof(buf) - 2 - static_cast<size_t>(n), fmt, ap);
    va_end(ap);
    if (m < 0) {
        m = 0;
    }
    size_t len = static_cast<size_t>(n) + static_cast<size_t>(m);
    if (len > sizeof(buf) - 2) {
        len = sizeof(buf) - 2;
    }
    buf[len++] = '\n';
    fwrite(buf, 1, len, f);
    fflush(f);
    g_bytes += len;
}

// ---- run-time resolved APIs ---------------------------------------------------------------------

struct Apis {
    HANDLE(WINAPI* OpenThread)(DWORD, BOOL, DWORD) = nullptr;
    DWORD(WINAPI* SuspendThread)(HANDLE) = nullptr;
    DWORD(WINAPI* ResumeThread)(HANDLE) = nullptr;
    BOOL(WINAPI* GetThreadContext)(HANDLE, LPCONTEXT) = nullptr;
    DWORD(WINAPI* GetProcessIdOfThread)(HANDLE) = nullptr;
    HRESULT(WINAPI* GetThreadDescription)(HANDLE, PWSTR*) = nullptr;
    HLOCAL(WINAPI* LocalFree)(HLOCAL) = nullptr;
    PVOID(WINAPI* AddVectoredExceptionHandler)(ULONG, PVECTORED_EXCEPTION_HANDLER) = nullptr;
    void(NTAPI* RtlCaptureContext)(PCONTEXT) = nullptr;
} g_api;

template <class T>
void Resolve(T& fn, const char* name, HMODULE a, HMODULE b, HMODULE c) {
    FARPROC p = nullptr;
    if (a != nullptr) {
        p = GetProcAddress(a, name);
    }
    if (p == nullptr && b != nullptr) {
        p = GetProcAddress(b, name);
    }
    if (p == nullptr && c != nullptr) {
        p = GetProcAddress(c, name);
    }
    fn = reinterpret_cast<T>(p);
}

void ResolveApis() {
    HMODULE k32 = GetModuleHandleW(L"kernel32.dll");
    HMODULE kb = GetModuleHandleW(L"kernelbase.dll");
    HMODULE nt = GetModuleHandleW(L"ntdll.dll");
    Resolve(g_api.OpenThread, "OpenThread", k32, kb, nullptr);
    Resolve(g_api.SuspendThread, "SuspendThread", k32, kb, nullptr);
    Resolve(g_api.ResumeThread, "ResumeThread", k32, kb, nullptr);
    Resolve(g_api.GetThreadContext, "GetThreadContext", k32, kb, nullptr);
    Resolve(g_api.GetProcessIdOfThread, "GetProcessIdOfThread", k32, kb, nullptr);
    Resolve(g_api.GetThreadDescription, "GetThreadDescription", kb, k32, nullptr);
    Resolve(g_api.LocalFree, "LocalFree", k32, kb, nullptr);
    Resolve(g_api.AddVectoredExceptionHandler, "AddVectoredExceptionHandler", k32, kb, nt);
    Resolve(g_api.RtlCaptureContext, "RtlCaptureContext", nt, k32, kb);
}

// ---- symbols ------------------------------------------------------------------------------------

struct SymEntry {
    uint32_t rva;
    uint32_t name; // offset into g_symText
};
std::vector<SymEntry> g_syms;
std::vector<char> g_symText;
std::atomic_bool g_symsReady{false};

void LoadSymbols() {
    FILE* f = _wfopen(L"symbols\\dusklight.sym", L"rb");
    if (f == nullptr) {
        Out("symbols: symbols\\dusklight.sym not found (errno %d): frames will show module + rva only", errno);
        return;
    }
    fseek(f, 0, SEEK_END);
    const long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size <= 64) {
        fclose(f);
        Out("symbols: file has only %ld bytes (this build has no symbol table)", size);
        return;
    }
    g_symText.resize(static_cast<size_t>(size) + 1);
    const size_t got = fread(g_symText.data(), 1, static_cast<size_t>(size), f);
    fclose(f);
    g_symText[got] = '\0';
    g_syms.reserve(got / 64 + 16);
    char* base = g_symText.data();
    char* p = base;
    char* end = base + got;
    while (p < end) {
        char* eol = static_cast<char*>(memchr(p, '\n', static_cast<size_t>(end - p)));
        if (eol == nullptr) {
            eol = end;
        }
        *eol = '\0';
        if (eol - p > 9) {
            char* q = nullptr;
            const unsigned long rva = strtoul(p, &q, 16);
            if (q != nullptr && *q == ' ') {
                g_syms.push_back(SymEntry{static_cast<uint32_t>(rva), static_cast<uint32_t>((q + 1) - base)});
            }
        }
        p = eol + 1;
    }
    std::sort(g_syms.begin(), g_syms.end(), [](const SymEntry& a, const SymEntry& b) { return a.rva < b.rva; });
    g_symsReady = true;
    Out("symbols: %zu functions loaded (%ld bytes)", g_syms.size(), size);
}

const char* LookupSym(uint32_t rva, uint32_t* disp) {
    if (!g_symsReady.load()) {
        return nullptr;
    }
    auto it = std::upper_bound(g_syms.begin(), g_syms.end(), rva,
                               [](uint32_t v, const SymEntry& e) { return v < e.rva; });
    if (it == g_syms.begin()) {
        return nullptr;
    }
    --it;
    *disp = rva - it->rva;
    return g_symText.data() + it->name;
}

void FormatFrame(char* out, size_t cap, uintptr_t pc) {
    MEMORY_BASIC_INFORMATION mbi;
    if (VirtualQuery(reinterpret_cast<LPCVOID>(pc), &mbi, sizeof(mbi)) == 0 || mbi.AllocationBase == nullptr) {
        snprintf(out, cap, "0x%llx (unmapped)", static_cast<unsigned long long>(pc));
        return;
    }
    const uintptr_t base = reinterpret_cast<uintptr_t>(mbi.AllocationBase);
    const unsigned long long rva = static_cast<unsigned long long>(pc - base);
    char path[260];
    path[0] = '\0';
    DWORD n = GetModuleFileNameA(reinterpret_cast<HMODULE>(base), path, sizeof(path) - 1);
    if (n >= sizeof(path)) {
        n = sizeof(path) - 1;
    }
    path[n] = '\0';
    const char* name = path;
    for (const char* c = path; *c != '\0'; ++c) {
        if (*c == '\\' || *c == '/') {
            name = c + 1;
        }
    }
    if (n == 0) {
        name = "(no module)";
    }
    if (base == g_exeBase) {
        uint32_t disp = 0;
        const char* sym = LookupSym(static_cast<uint32_t>(rva), &disp);
        if (sym != nullptr) {
            snprintf(out, cap, "%s!%s+0x%x (rva 0x%llx)", name, sym, disp, rva);
            return;
        }
    }
    snprintf(out, cap, "%s+0x%llx", name, rva);
}

void LogFrames(const uintptr_t* pcs, int n) {
    char text[512];
    for (int i = 0; i < n; ++i) {
        FormatFrame(text, sizeof(text), pcs[i]);
        Out("  #%02d %s", i, text);
    }
}

// ---- stack unwinding ----------------------------------------------------------------------------

#if defined(_M_X64)
// Plain function on purpose (no C++ objects) so it can use SEH.
int Unwind(CONTEXT ctx, uintptr_t* out, int cap) {
    int n = 0;
    __try {
        DWORD64 prevSp = 0;
        while (n < cap) {
            const DWORD64 ip = ctx.Rip;
            if (ip == 0) {
                break;
            }
            out[n++] = static_cast<uintptr_t>(ip);
            DWORD64 imageBase = 0;
            PRUNTIME_FUNCTION fn = RtlLookupFunctionEntry(ip, &imageBase, nullptr);
            if (fn != nullptr) {
                PVOID handlerData = nullptr;
                DWORD64 establisherFrame = 0;
                RtlVirtualUnwind(UNW_FLAG_NHANDLER, imageBase, ip, fn, &ctx, &handlerData, &establisherFrame,
                                 nullptr);
            } else {
                if (ctx.Rsp == 0) {
                    break;
                }
                ctx.Rip = *reinterpret_cast<const DWORD64*>(ctx.Rsp);
                ctx.Rsp += sizeof(DWORD64);
            }
            if (ctx.Rsp <= prevSp) {
                break;
            }
            prevSp = ctx.Rsp;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
    }
    return n;
}
#else
int Unwind(CONTEXT, uintptr_t*, int) {
    return 0;
}
#endif

void LogCurrentStack(const char* title) {
    if (g_api.RtlCaptureContext == nullptr) {
        Out("==== %s on tid %lu (no RtlCaptureContext, stack unavailable) ====", title,
            static_cast<unsigned long>(GetCurrentThreadId()));
        return;
    }
    CONTEXT ctx;
    std::memset(&ctx, 0, sizeof(ctx));
    g_api.RtlCaptureContext(&ctx);
    uintptr_t pcs[40];
    const int n = Unwind(ctx, pcs, 40);
    Out("==== %s on tid %lu (main tid %lu) ====", title, static_cast<unsigned long>(GetCurrentThreadId()),
        static_cast<unsigned long>(g_mainTid));
    LogFrames(pcs, n);
}

// ---- exception / abort hooks --------------------------------------------------------------------

std::atomic<int> g_reports{0};
thread_local bool tl_inHandler = false;

bool IsInteresting(DWORD code) {
    switch (code) {
    case 0xC0000005: // access violation
    case 0xC000001D: // illegal instruction
    case 0xC0000096: // privileged instruction
    case 0xC0000094: // integer divide by zero
    case 0xC000008C: // array bounds exceeded
    case 0xC00000FD: // stack overflow
    case 0xC0000374: // heap corruption
    case 0xC0000409: // stack buffer overrun / fast fail
    case 0xC0000420: // assertion failure
    case 0xC0000025: // non-continuable exception
    case 0xC0000194: // possible deadlock
    case 0x80000003: // breakpoint (assert / DebugBreak)
        return true;
    default:
        return false;
    }
}

LONG CALLBACK VehHandler(EXCEPTION_POINTERS* ep) {
    const EXCEPTION_RECORD* er = ep->ExceptionRecord;
    const DWORD code = er->ExceptionCode;
    if (tl_inHandler || !IsInteresting(code)) {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    if (g_reports.fetch_add(1) >= 30) {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    tl_inHandler = true;
    Out("==== EXCEPTION 0x%08lx at 0x%llx on tid %lu (main tid %lu; first chance, the program may handle it) ====",
        static_cast<unsigned long>(code), static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(er->ExceptionAddress)),
        static_cast<unsigned long>(GetCurrentThreadId()), static_cast<unsigned long>(g_mainTid));
    if (code == EXCEPTION_ACCESS_VIOLATION && er->NumberParameters >= 2) {
        const ULONG_PTR kind = er->ExceptionInformation[0];
        Out("  access violation: %s address 0x%llx", kind == 0 ? "read of" : (kind == 1 ? "write to" : "execute of"),
            static_cast<unsigned long long>(er->ExceptionInformation[1]));
    }
    uintptr_t pcs[40];
    const int n = Unwind(*ep->ContextRecord, pcs, 40);
    LogFrames(pcs, n);
    tl_inHandler = false;
    return EXCEPTION_CONTINUE_SEARCH;
}

void __cdecl OnSigAbort(int) {
    LogCurrentStack("abort() called");
}

std::terminate_handler g_prevTerminate = nullptr;

void OnTerminate() {
    char msg[300];
    msg[0] = '\0';
    try {
        std::exception_ptr ep = std::current_exception();
        if (ep) {
            std::rethrow_exception(ep);
        }
    } catch (const std::exception& e) {
        snprintf(msg, sizeof(msg), "std::terminate: uncaught std::exception: %s", e.what());
    } catch (...) {
        snprintf(msg, sizeof(msg), "std::terminate: uncaught non-std exception");
    }
    LogCurrentStack(msg[0] != '\0' ? msg : "std::terminate (no active exception)");
    if (g_prevTerminate != nullptr) {
        g_prevTerminate();
    }
    std::abort();
}

void __cdecl OnInvalidParameter(const wchar_t* expression, const wchar_t* function, const wchar_t* file,
                                unsigned int line, uintptr_t) {
    char title[400];
    snprintf(title, sizeof(title), "invalid CRT parameter: expr=%ls func=%ls file=%ls line=%u",
             expression != nullptr ? expression : L"?", function != nullptr ? function : L"?",
             file != nullptr ? file : L"?", line);
    LogCurrentStack(title);
}

// ---- watchdog: disc statistics + stack dumps of every thread -----------------------------------

struct ThreadDump {
    DWORD tid;
    char name[64];
    int n;
    uintptr_t pcs[24];
};
ThreadDump g_dumps[160];

void DumpAllThreads(const char* why) {
    if (g_api.OpenThread == nullptr || g_api.SuspendThread == nullptr || g_api.ResumeThread == nullptr ||
        g_api.GetThreadContext == nullptr) {
        Out("thread dump '%s' unavailable (OpenThread/SuspendThread/GetThreadContext missing)", why);
        return;
    }
    const DWORD self = GetCurrentThreadId();
    const DWORD pid = GetCurrentProcessId();
    const ULONGLONG t0 = GetTickCount64();
    int count = 0;
    // Thread ids are multiples of 4. In an app container OpenThread only succeeds for the threads of this
    // process, so scanning the id range finds exactly our threads.
    for (DWORD tid = 4; tid < 0x40000 && count < 160; tid += 4) {
        if (tid == self) {
            continue;
        }
        HANDLE h = g_api.OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, tid);
        if (h == nullptr) {
            continue;
        }
        if (g_api.GetProcessIdOfThread != nullptr && g_api.GetProcessIdOfThread(h) != pid) {
            CloseHandle(h);
            continue;
        }
        ThreadDump& d = g_dumps[count];
        d.tid = tid;
        d.n = 0;
        d.name[0] = '\0';
        if (g_api.GetThreadDescription != nullptr) {
            PWSTR w = nullptr;
            if (SUCCEEDED(g_api.GetThreadDescription(h, &w)) && w != nullptr) {
                WideCharToMultiByte(CP_UTF8, 0, w, -1, d.name, static_cast<int>(sizeof(d.name)) - 1, nullptr, nullptr);
                d.name[sizeof(d.name) - 1] = '\0';
                if (g_api.LocalFree != nullptr) {
                    g_api.LocalFree(w);
                }
            }
        }
        // Only memory that already exists is touched while the thread is suspended (it may hold the heap lock).
        if (g_api.SuspendThread(h) != static_cast<DWORD>(-1)) {
            CONTEXT ctx;
            std::memset(&ctx, 0, sizeof(ctx));
            ctx.ContextFlags = CONTEXT_CONTROL | CONTEXT_INTEGER;
            if (g_api.GetThreadContext(h, &ctx)) {
                d.n = Unwind(ctx, d.pcs, 24);
            }
            g_api.ResumeThread(h);
        }
        CloseHandle(h);
        ++count;
    }
    Out("==== thread dump (%s): %d threads, took %llu ms; main tid %lu ====", why, count,
        static_cast<unsigned long long>(GetTickCount64() - t0), static_cast<unsigned long>(g_mainTid));
    for (int i = 0; i < count; ++i) {
        const ThreadDump& d = g_dumps[i];
        Out("thread %lu '%s'%s, %d frames", static_cast<unsigned long>(d.tid), d.name,
            d.tid == g_mainTid ? " [game thread]" : "", d.n);
        LogFrames(d.pcs, d.n);
    }
}

void LogDisc(const unsigned long long* s) {
    Out("disc: opens=%llu reads=%llu bytes=%llu errors=%llu slow=%llu inRead=%llu inReadSince=%llu lastOff=%lld "
        "lastLen=%llu lastDone=%llu",
        s[0], s[1], s[2], s[3], s[4], s[5], s[6], static_cast<long long>(s[7]), s[8], s[9]);
}

void Watchdog() {
    Out("watchdog started");
    LoadSymbols();
    const ULONGLONG t0 = GetTickCount64();
    ULONGLONG anchor = 0;
    ULONGLONG lastLog = 0;
    ULONGLONG lastStallDump = 0;
    int stallDumps = 0;
    int anchorDumps = 0;
    bool early[2] = {false, false};
    unsigned long long last[10] = {};
    static const ULONGLONG kAnchorMs[] = {6000, 15000, 40000, 90000, 180000, 420000};
    for (int i = 0; i < 3000; ++i) { // ~50 minutes
        std::this_thread::sleep_for(std::chrono::seconds(1));
        const ULONGLONG now = GetTickCount64();
        unsigned long long s[10] = {};
        dusk_xbox_disc_stats(s);
        const bool changed = std::memcmp(s, last, sizeof(s)) != 0;
        if ((changed && now - lastLog >= 2000) || now - lastLog >= 20000) {
            LogDisc(s);
            std::memcpy(last, s, sizeof(s));
            lastLog = now;
        }
        // Opens of the disc: 1 = inspection, 2 = verification, 3 = the game itself.
        if (anchor == 0 && s[0] >= 3) {
            anchor = now;
            Out("the game opened the disc (open #%llu), thread dumps scheduled", s[0]);
        }
        if (anchor != 0 && anchorDumps < 6 && now - anchor >= kAnchorMs[anchorDumps]) {
            char why[64];
            snprintf(why, sizeof(why), "game start +%llu ms", static_cast<unsigned long long>(now - anchor));
            ++anchorDumps;
            DumpAllThreads(why);
        }
        if (!early[0] && now - t0 >= 150000) {
            early[0] = true;
            DumpAllThreads("process start +150 s");
        }
        if (!early[1] && now - t0 >= 400000) {
            early[1] = true;
            DumpAllThreads("process start +400 s");
        }
        // A disc read that has been running for more than 10 s.
        if (s[5] > 0 && s[5] < 1000 && now > s[6] && now - s[6] > 10000 && stallDumps < 3 &&
            now - lastStallDump > 60000) {
            ++stallDumps;
            lastStallDump = now;
            DumpAllThreads("disc read stalled for more than 10 s");
        }
    }
    Out("watchdog finished");
}

} // namespace

void dusk_xbox_crash_diag_start(const wchar_t* dir) {
    if (g_started.exchange(true) || dir == nullptr) {
        return;
    }
    std::wstring path = dir;
    path += L"\\crash-diag.log";
    g_file = _wfopen(path.c_str(), L"w");
    if (g_file == nullptr) {
        return;
    }
    g_mainTid = GetCurrentThreadId();
    g_exeBase = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
    ResolveApis();
    Out("crash diagnostics: game thread tid %lu, exe base 0x%llx; apis: veh=%d capture=%d openThread=%d "
        "suspend=%d getContext=%d threadName=%d",
        static_cast<unsigned long>(g_mainTid), static_cast<unsigned long long>(g_exeBase),
        g_api.AddVectoredExceptionHandler != nullptr, g_api.RtlCaptureContext != nullptr,
        g_api.OpenThread != nullptr, g_api.SuspendThread != nullptr, g_api.GetThreadContext != nullptr,
        g_api.GetThreadDescription != nullptr);
    if (g_api.AddVectoredExceptionHandler != nullptr) {
        g_api.AddVectoredExceptionHandler(1, &VehHandler);
    }
    std::signal(SIGABRT, &OnSigAbort);
    _set_invalid_parameter_handler(&OnInvalidParameter);
    g_prevTerminate = std::set_terminate(&OnTerminate);
    try {
        std::thread(Watchdog).detach();
    } catch (...) {
        Out("failed to start the watchdog thread");
    }
}
