// Xbox (UWP) startup graphics probe. Compiled into the dusklight target only for the Xbox build
// (platforms/xbox/xbox-project.cmake); called from game_main() right before aurora_initialize() via
// a CI-time patch (platforms/xbox/Apply-Patches.ps1).
//
// Why: on an Xbox One S the game died with EXCEPTION_ACCESS_VIOLATION inside the console's D3D12
// user-mode driver (umd12ddi.dll, reached through D3D12Core.dll) while Dawn created its D3D12 device,
// and the in-memory log was lost with the crash. This probe repeats the device creation steps that
// Dawn performs, one at a time:
//   * every step is written to <cache dir>/gfx-probe.log and flushed BEFORE the call is made, so the
//     last line survives even a crash that cannot be caught;
//   * every driver call runs under SEH (__try/__except), so an access violation is caught and logged
//     instead of killing the app.
// The result decides which backend Aurora may use (see dusk_xbox_probe_graphics below).
//
// Only plain C-style code lives inside the functions that contain __try (MSVC forbids object
// unwinding there), hence the small callback structs.

#include <windows.h>
#include <d3d11.h>
#include <d3d12.h>
#include <dxgi.h>

#include <cstdarg>
#include <cstdio>
#include <filesystem>

#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "d3d12.lib")

namespace {

FILE* g_probeLog = nullptr;

void PLog(const char* fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    buf[sizeof(buf) - 1] = '\0';
    OutputDebugStringA(buf);
    OutputDebugStringA("\n");
    if (g_probeLog != nullptr) {
        fputs(buf, g_probeLog);
        fputc('\n', g_probeLog);
        fflush(g_probeLog);
    }
}

unsigned long Hr(HRESULT hr) {
    return static_cast<unsigned long>(hr);
}

using ProbeFn = void (*)(void*);

// Runs fn(ctx); returns false if it raised an SEH exception (logged).
bool RunGuarded(const char* what, ProbeFn fn, void* ctx) {
    DWORD code = 0;
    __try {
        fn(ctx);
    } __except (code = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) {
        PLog("  !! %s: SEH exception 0x%08lX caught", what, static_cast<unsigned long>(code));
        return false;
    }
    return true;
}

// ---- DXGI ------------------------------------------------------------------------------------
struct FactoryCtx {
    IDXGIFactory1* factory;
    HRESULT hr;
};

void CreateFactoryFn(void* p) {
    auto* c = static_cast<FactoryCtx*>(p);
    c->hr = CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void**>(&c->factory));
}

// ---- D3D11 -----------------------------------------------------------------------------------
struct D3D11Ctx {
    IDXGIAdapter* adapter;
    const D3D_FEATURE_LEVEL* levels;
    UINT count;
    ID3D11Device* dev;
    D3D_FEATURE_LEVEL got;
    HRESULT hr;
};

void D3D11CreateFn(void* p) {
    auto* c = static_cast<D3D11Ctx*>(p);
    c->hr = D3D11CreateDevice(c->adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0, c->levels, c->count,
        D3D11_SDK_VERSION, &c->dev, &c->got, nullptr);
}

// ---- D3D12 -----------------------------------------------------------------------------------
struct D3D12Ctx {
    IUnknown* adapter;
    D3D_FEATURE_LEVEL fl;
    bool checkOnly;
    ID3D12Device* dev;
    HRESULT hr;
};

void D3D12CreateFn(void* p) {
    auto* c = static_cast<D3D12Ctx*>(p);
    c->hr = D3D12CreateDevice(c->adapter, c->fl, __uuidof(ID3D12Device),
        c->checkOnly ? nullptr : reinterpret_cast<void**>(&c->dev));
}

// What Dawn's D3D12 PhysicalDevice::Initialize does after creating the device, plus the first
// resource creation. Each step is logged before it runs.
void D3D12QueriesFn(void* p) {
    ID3D12Device* d = static_cast<ID3D12Device*>(p);
    HRESULT hr;

    PLog("  [q1] CheckFeatureSupport(D3D12_OPTIONS)");
    D3D12_FEATURE_DATA_D3D12_OPTIONS o = {};
    hr = d->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS, &o, sizeof(o));
    PLog("       hr=0x%08lX ResourceBindingTier=%d TiledResourcesTier=%d ConservativeRasterizationTier=%d",
        Hr(hr), static_cast<int>(o.ResourceBindingTier), static_cast<int>(o.TiledResourcesTier),
        static_cast<int>(o.ConservativeRasterizationTier));

    PLog("  [q2] CheckFeatureSupport(FEATURE_LEVELS)");
    static const D3D_FEATURE_LEVEL kLevels[] = {D3D_FEATURE_LEVEL_12_1, D3D_FEATURE_LEVEL_12_0,
        D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
    D3D12_FEATURE_DATA_FEATURE_LEVELS fl = {};
    fl.NumFeatureLevels = 4;
    fl.pFeatureLevelsRequested = kLevels;
    hr = d->CheckFeatureSupport(D3D12_FEATURE_FEATURE_LEVELS, &fl, sizeof(fl));
    PLog("       hr=0x%08lX MaxSupportedFeatureLevel=0x%04X", Hr(hr),
        static_cast<unsigned>(fl.MaxSupportedFeatureLevel));

    PLog("  [q3] CheckFeatureSupport(SHADER_MODEL, 6.6 requested)");
    D3D12_FEATURE_DATA_SHADER_MODEL sm = {};
    sm.HighestShaderModel = D3D_SHADER_MODEL_6_6;
    hr = d->CheckFeatureSupport(D3D12_FEATURE_SHADER_MODEL, &sm, sizeof(sm));
    PLog("       hr=0x%08lX HighestShaderModel=0x%02X", Hr(hr), static_cast<unsigned>(sm.HighestShaderModel));

    PLog("  [q4] CheckFeatureSupport(ARCHITECTURE1)");
    D3D12_FEATURE_DATA_ARCHITECTURE1 a = {};
    hr = d->CheckFeatureSupport(D3D12_FEATURE_ARCHITECTURE1, &a, sizeof(a));
    PLog("       hr=0x%08lX UMA=%d CacheCoherentUMA=%d IsolatedMMU=%d", Hr(hr), static_cast<int>(a.UMA),
        static_cast<int>(a.CacheCoherentUMA), static_cast<int>(a.IsolatedMMU));

    PLog("  [q5] CheckFeatureSupport(FORMAT_SUPPORT BGRA8)");
    D3D12_FEATURE_DATA_FORMAT_SUPPORT fs = {};
    fs.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    hr = d->CheckFeatureSupport(D3D12_FEATURE_FORMAT_SUPPORT, &fs, sizeof(fs));
    PLog("       hr=0x%08lX Support1=0x%08X Support2=0x%08X", Hr(hr), static_cast<unsigned>(fs.Support1),
        static_cast<unsigned>(fs.Support2));

    PLog("  [q6] CreateCommandQueue(DIRECT)");
    D3D12_COMMAND_QUEUE_DESC qd = {};
    qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    ID3D12CommandQueue* q = nullptr;
    hr = d->CreateCommandQueue(&qd, __uuidof(ID3D12CommandQueue), reinterpret_cast<void**>(&q));
    PLog("       hr=0x%08lX", Hr(hr));
    if (SUCCEEDED(hr) && q != nullptr) {
        PLog("  [q7] GetTimestampFrequency");
        UINT64 freq = 0;
        hr = q->GetTimestampFrequency(&freq);
        PLog("       hr=0x%08lX freq=%llu", Hr(hr), static_cast<unsigned long long>(freq));
        q->Release();
    }

    PLog("  [q8] CreateFence");
    ID3D12Fence* fence = nullptr;
    hr = d->CreateFence(0, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence), reinterpret_cast<void**>(&fence));
    PLog("       hr=0x%08lX", Hr(hr));
    if (fence != nullptr) {
        fence->Release();
    }

    PLog("  [q9] CreateCommandAllocator(DIRECT)");
    ID3D12CommandAllocator* alloc = nullptr;
    hr = d->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, __uuidof(ID3D12CommandAllocator),
        reinterpret_cast<void**>(&alloc));
    PLog("       hr=0x%08lX", Hr(hr));
    if (alloc != nullptr) {
        alloc->Release();
    }

    PLog("  [q10] CreateCommittedResource(64 KiB upload buffer)");
    D3D12_HEAP_PROPERTIES hp = {};
    hp.Type = D3D12_HEAP_TYPE_UPLOAD;
    hp.CreationNodeMask = 1;
    hp.VisibleNodeMask = 1;
    D3D12_RESOURCE_DESC rd = {};
    rd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    rd.Width = 65536;
    rd.Height = 1;
    rd.DepthOrArraySize = 1;
    rd.MipLevels = 1;
    rd.Format = DXGI_FORMAT_UNKNOWN;
    rd.SampleDesc.Count = 1;
    rd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    ID3D12Resource* res = nullptr;
    hr = d->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &rd, D3D12_RESOURCE_STATE_GENERIC_READ,
        nullptr, __uuidof(ID3D12Resource), reinterpret_cast<void**>(&res));
    PLog("       hr=0x%08lX", Hr(hr));
    if (res != nullptr) {
        res->Release();
    }
}

void NarrowName(const WCHAR* wide, char* out, int outSize) {
    out[0] = '\0';
    WideCharToMultiByte(CP_UTF8, 0, wide, -1, out, outSize, nullptr, nullptr);
    out[outSize - 1] = '\0';
}

}  // namespace

// Result bits.
//   1: a hardware adapter completed D3D12 device creation and the follow-up queries without a crash
//   2: a hardware adapter offers a D3D11 device with feature level >= 11.0 (what Dawn's D3D11 needs)
//   4: the probe could not run at all (no DXGI factory); callers should not act on bits 1/2
int dusk_xbox_probe_graphics(const wchar_t* dir) {
    std::filesystem::path path = (dir != nullptr) ? std::filesystem::path(dir) : std::filesystem::path();
    path /= L"gfx-probe.log";
    if (_wfopen_s(&g_probeLog, path.c_str(), L"w") != 0) {
        g_probeLog = nullptr;
    }

    PLog("=== Dusklight Xbox graphics probe ===");
    int result = 0;

    FactoryCtx fc = {};
    fc.hr = E_FAIL;
    PLog("CreateDXGIFactory1");
    if (!RunGuarded("CreateDXGIFactory1", CreateFactoryFn, &fc) || FAILED(fc.hr) || fc.factory == nullptr) {
        PLog("  CreateDXGIFactory1 failed (hr=0x%08lX), probe inconclusive", Hr(fc.hr));
        if (g_probeLog != nullptr) {
            fclose(g_probeLog);
            g_probeLog = nullptr;
        }
        return 4;
    }

    bool d3d12Crashed = false;
    for (UINT i = 0; i < 16; ++i) {
        IDXGIAdapter1* ad = nullptr;
        const HRESULT enumHr = fc.factory->EnumAdapters1(i, &ad);
        if (FAILED(enumHr) || ad == nullptr) {
            break;
        }
        DXGI_ADAPTER_DESC1 d = {};
        ad->GetDesc1(&d);
        char name[256];
        NarrowName(d.Description, name, static_cast<int>(sizeof(name)));
        const bool software = (d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0;
        PLog("Adapter %u: '%s' vendor=0x%04X device=0x%04X flags=0x%X dedicatedVRAM=%llu MiB sharedSysMem=%llu MiB%s",
            i, name, d.VendorId, d.DeviceId, d.Flags,
            static_cast<unsigned long long>(d.DedicatedVideoMemory >> 20),
            static_cast<unsigned long long>(d.SharedSystemMemory >> 20), software ? " (software)" : "");

        // ---- D3D11 ----
        static const D3D_FEATURE_LEVEL kL11[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
            D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
        for (UINT skip = 0; skip < 3; ++skip) {
            D3D11Ctx c = {};
            c.adapter = ad;
            c.levels = kL11 + skip;
            c.count = 4 - skip;
            c.hr = E_FAIL;
            PLog("  D3D11CreateDevice(levels from 0x%04X)", static_cast<unsigned>(c.levels[0]));
            const bool ok = RunGuarded("D3D11CreateDevice", D3D11CreateFn, &c);
            PLog("       hr=0x%08lX featureLevel=0x%04X", Hr(c.hr), static_cast<unsigned>(c.got));
            if (ok && SUCCEEDED(c.hr) && c.dev != nullptr) {
                if (!software && c.got >= D3D_FEATURE_LEVEL_11_0) {
                    result |= 2;
                }
                c.dev->Release();
                break;
            }
        }

        // ---- D3D12 (hardware adapters only; stop after the first crash) ----
        if (!software && !d3d12Crashed) {
            D3D12Ctx chk = {};
            chk.adapter = ad;
            chk.fl = D3D_FEATURE_LEVEL_11_0;
            chk.checkOnly = true;
            chk.hr = E_FAIL;
            PLog("  D3D12CreateDevice(FL 11_0, support check only)");
            if (!RunGuarded("D3D12CreateDevice(check)", D3D12CreateFn, &chk)) {
                d3d12Crashed = true;
            } else {
                PLog("       hr=0x%08lX", Hr(chk.hr));
                D3D12Ctx cr = {};
                cr.adapter = ad;
                cr.fl = D3D_FEATURE_LEVEL_11_0;
                cr.checkOnly = false;
                cr.hr = E_FAIL;
                PLog("  D3D12CreateDevice(FL 11_0, real device)");
                if (!RunGuarded("D3D12CreateDevice(real)", D3D12CreateFn, &cr)) {
                    d3d12Crashed = true;
                } else {
                    PLog("       hr=0x%08lX device=%p", Hr(cr.hr), static_cast<void*>(cr.dev));
                    if (SUCCEEDED(cr.hr) && cr.dev != nullptr) {
                        if (RunGuarded("D3D12 queries", D3D12QueriesFn, cr.dev)) {
                            result |= 1;
                        } else {
                            d3d12Crashed = true;
                        }
                        cr.dev->Release();
                    }
                }
            }
        }
        ad->Release();
    }
    fc.factory->Release();

    if (d3d12Crashed) {
        result &= ~1;
    }
    PLog("=== probe result: d3d12=%s d3d11_fl11=%s d3d12_crashed=%s ===", (result & 1) ? "ok" : "no",
        (result & 2) ? "ok" : "no", d3d12Crashed ? "YES" : "no");
    if (g_probeLog != nullptr) {
        fclose(g_probeLog);
        g_probeLog = nullptr;
    }
    return result;
}
