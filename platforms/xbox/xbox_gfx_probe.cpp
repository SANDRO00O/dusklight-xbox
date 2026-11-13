// Xbox (UWP) startup graphics probe. Compiled into the dusklight target only for the Xbox build
// (platforms/xbox/xbox-project.cmake); called from game_main() right before aurora_initialize() via
// a CI-time patch (platforms/xbox/Apply-Patches.ps1).
//
// Why: on an Xbox One S the game died with EXCEPTION_ACCESS_VIOLATION inside the console's D3D12
// user-mode driver (umd12ddi.dll, reached through D3D12Core.dll) while Aurora/Dawn initialised the
// D3D12 backend, and the in-memory log was lost with the crash. The first version of this probe
// showed that creating the device and the basic queries work (feature level 12_0, shader model 5.1,
// UMA), so the crash is in a later step. This version repeats, one step at a time, what Dawn's
// D3D12 backend does while creating the adapter and the device:
//   * every step is written to <cache dir>/gfx-probe.log and flushed BEFORE the call is made, so the
//     last line survives even a crash that cannot be caught;
//   * every step runs under SEH (__try/__except), so an access violation is caught, logged, and the
//     probe continues with the next step.
// The result decides which backend Aurora may use (see dusk_xbox_probe_graphics below).
//
// Only plain C-style code lives inside the functions that contain __try (MSVC forbids object
// unwinding there), hence the small callback structs and step functions.

#include <windows.h>
#include <d3d11.h>
#include <d3d12.h>
#include <d3dcompiler.h>
#include <dxgi.h>

#include <climits>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <filesystem>

#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "d3d12.lib")
#pragma comment(lib, "d3dcompiler.lib")

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

// ---- D3D12 device creation -------------------------------------------------------------------
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

// ---- D3D12 steps (the parameter is the ID3D12Device*) ----------------------------------------
// First the queries of Dawn's GatherDeviceInfo (d3d12/D3D12Info.cpp), in Dawn's order, then the
// rest of PhysicalDevice/Device initialisation.

#define PROBE_DEV static_cast<ID3D12Device*>(p)

template <typename T>
HRESULT Query(ID3D12Device* d, D3D12_FEATURE f, T* t) {
    return d->CheckFeatureSupport(f, t, sizeof(T));
}

void StepArchitecture(void* p) {
    D3D12_FEATURE_DATA_ARCHITECTURE a = {};
    const HRESULT hr = Query(PROBE_DEV, D3D12_FEATURE_ARCHITECTURE, &a);
    PLog("       hr=0x%08lX UMA=%d CacheCoherentUMA=%d", Hr(hr), static_cast<int>(a.UMA),
        static_cast<int>(a.CacheCoherentUMA));
}

void StepArchitecture1(void* p) {
    D3D12_FEATURE_DATA_ARCHITECTURE1 a = {};
    const HRESULT hr = Query(PROBE_DEV, D3D12_FEATURE_ARCHITECTURE1, &a);
    PLog("       hr=0x%08lX UMA=%d CacheCoherentUMA=%d IsolatedMMU=%d", Hr(hr), static_cast<int>(a.UMA),
        static_cast<int>(a.CacheCoherentUMA), static_cast<int>(a.IsolatedMMU));
}

void StepOptions(void* p) {
    D3D12_FEATURE_DATA_D3D12_OPTIONS o = {};
    const HRESULT hr = Query(PROBE_DEV, D3D12_FEATURE_D3D12_OPTIONS, &o);
    PLog("       hr=0x%08lX ResourceHeapTier=%d ResourceBindingTier=%d TiledResourcesTier=%d", Hr(hr),
        static_cast<int>(o.ResourceHeapTier), static_cast<int>(o.ResourceBindingTier),
        static_cast<int>(o.TiledResourcesTier));
}

void StepOptions2(void* p) {
    D3D12_FEATURE_DATA_D3D12_OPTIONS2 o = {};
    const HRESULT hr = Query(PROBE_DEV, D3D12_FEATURE_D3D12_OPTIONS2, &o);
    PLog("       hr=0x%08lX ProgrammableSamplePositionsTier=%d", Hr(hr),
        static_cast<int>(o.ProgrammableSamplePositionsTier));
}

void StepOptions3(void* p) {
    D3D12_FEATURE_DATA_D3D12_OPTIONS3 o = {};
    const HRESULT hr = Query(PROBE_DEV, D3D12_FEATURE_D3D12_OPTIONS3, &o);
    PLog("       hr=0x%08lX CastingFullyTypedFormatSupported=%d", Hr(hr),
        static_cast<int>(o.CastingFullyTypedFormatSupported));
}

void StepOptions4(void* p) {
    D3D12_FEATURE_DATA_D3D12_OPTIONS4 o = {};
    const HRESULT hr = Query(PROBE_DEV, D3D12_FEATURE_D3D12_OPTIONS4, &o);
    PLog("       hr=0x%08lX SharedResourceCompatibilityTier=%d MSAA64KBAligned=%d Native16Bit=%d", Hr(hr),
        static_cast<int>(o.SharedResourceCompatibilityTier), static_cast<int>(o.MSAA64KBAlignedTextureSupported),
        static_cast<int>(o.Native16BitShaderOpsSupported));
}

void StepOptions7(void* p) {
    D3D12_FEATURE_DATA_D3D12_OPTIONS7 o = {};
    const HRESULT hr = Query(PROBE_DEV, D3D12_FEATURE_D3D12_OPTIONS7, &o);
    PLog("       hr=0x%08lX MeshShaderTier=%d SamplerFeedbackTier=%d", Hr(hr),
        static_cast<int>(o.MeshShaderTier), static_cast<int>(o.SamplerFeedbackTier));
}

void StepOptions8(void* p) {
    D3D12_FEATURE_DATA_D3D12_OPTIONS8 o = {};
    const HRESULT hr = Query(PROBE_DEV, D3D12_FEATURE_D3D12_OPTIONS8, &o);
    PLog("       hr=0x%08lX UnalignedBlockTexturesSupported=%d", Hr(hr),
        static_cast<int>(o.UnalignedBlockTexturesSupported));
}

void StepOptions13(void* p) {
    D3D12_FEATURE_DATA_D3D12_OPTIONS13 o = {};
    const HRESULT hr = Query(PROBE_DEV, D3D12_FEATURE_D3D12_OPTIONS13, &o);
    PLog("       hr=0x%08lX TextureCopyBetweenDimensionsSupported=%d", Hr(hr),
        static_cast<int>(o.TextureCopyBetweenDimensionsSupported));
}

void StepOptions18(void* p) {
    // D3D12_FEATURE_D3D12_OPTIONS18 = 47 (Agility SDK 1.612+); local struct in case the SDK is older.
    struct Opt18 {
        BOOL RenderPassesValid;
    } o = {};
    const HRESULT hr = PROBE_DEV->CheckFeatureSupport(static_cast<D3D12_FEATURE>(47), &o, sizeof(o));
    PLog("       hr=0x%08lX RenderPassesValid=%d", Hr(hr), static_cast<int>(o.RenderPassesValid));
}

void StepRootSignatureFeature(void* p) {
    D3D12_FEATURE_DATA_ROOT_SIGNATURE o = {};
    o.HighestVersion = D3D_ROOT_SIGNATURE_VERSION_1_1;
    const HRESULT hr = Query(PROBE_DEV, D3D12_FEATURE_ROOT_SIGNATURE, &o);
    PLog("       hr=0x%08lX HighestVersion=0x%X", Hr(hr), static_cast<unsigned>(o.HighestVersion));
}

void StepExistingHeaps(void* p) {
    D3D12_FEATURE_DATA_EXISTING_HEAPS o = {};
    const HRESULT hr = Query(PROBE_DEV, D3D12_FEATURE_EXISTING_HEAPS, &o);
    PLog("       hr=0x%08lX Supported=%d", Hr(hr), static_cast<int>(o.Supported));
}

void StepShaderModels(void* p) {
    // Dawn walks 6.10(Agility only)/6.9 ... 6.0 / 5.1 downwards until one query succeeds.
    static const int kModels[] = {0x69, 0x68, 0x67, 0x66, 0x65, 0x64, 0x63, 0x62, 0x61, 0x60, 0x51};
    for (int m : kModels) {
        D3D12_FEATURE_DATA_SHADER_MODEL o = {};
        o.HighestShaderModel = static_cast<D3D_SHADER_MODEL>(m);
        PLog("       requesting 0x%02X", static_cast<unsigned>(m));
        const HRESULT hr = Query(PROBE_DEV, D3D12_FEATURE_SHADER_MODEL, &o);
        PLog("       hr=0x%08lX HighestShaderModel=0x%02X", Hr(hr), static_cast<unsigned>(o.HighestShaderModel));
        if (SUCCEEDED(hr)) {
            break;
        }
    }
}

void StepFeatureLevels(void* p) {
    static const D3D_FEATURE_LEVEL kLevels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
    D3D12_FEATURE_DATA_FEATURE_LEVELS o = {};
    o.NumFeatureLevels = 2;
    o.pFeatureLevelsRequested = kLevels;
    const HRESULT hr = Query(PROBE_DEV, D3D12_FEATURE_FEATURE_LEVELS, &o);
    PLog("       hr=0x%08lX MaxSupportedFeatureLevel=0x%04X", Hr(hr), static_cast<unsigned>(o.MaxSupportedFeatureLevel));
}

void StepFormatSupport(void* p) {
    static const DXGI_FORMAT kFormats[] = {DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_FORMAT_R8_UNORM};
    for (DXGI_FORMAT f : kFormats) {
        D3D12_FEATURE_DATA_FORMAT_SUPPORT o = {};
        o.Format = f;
        const HRESULT hr = Query(PROBE_DEV, D3D12_FEATURE_FORMAT_SUPPORT, &o);
        PLog("       format %d: hr=0x%08lX Support1=0x%08X Support2=0x%08X", static_cast<int>(f), Hr(hr),
            static_cast<unsigned>(o.Support1), static_cast<unsigned>(o.Support2));
    }
}

void StepQueue(void* p) {
    D3D12_COMMAND_QUEUE_DESC qd = {};
    qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    ID3D12CommandQueue* q = nullptr;
    HRESULT hr = PROBE_DEV->CreateCommandQueue(&qd, __uuidof(ID3D12CommandQueue), reinterpret_cast<void**>(&q));
    PLog("       CreateCommandQueue hr=0x%08lX", Hr(hr));
    if (SUCCEEDED(hr) && q != nullptr) {
        UINT64 freq = 0;
        hr = q->GetTimestampFrequency(&freq);
        PLog("       GetTimestampFrequency hr=0x%08lX freq=%llu", Hr(hr), static_cast<unsigned long long>(freq));
        q->Release();
    }
}

void StepFenceAndAllocator(void* p) {
    ID3D12Fence* fence = nullptr;
    HRESULT hr = PROBE_DEV->CreateFence(0, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence), reinterpret_cast<void**>(&fence));
    PLog("       CreateFence hr=0x%08lX", Hr(hr));
    if (fence != nullptr) {
        fence->Release();
    }
    ID3D12CommandAllocator* alloc = nullptr;
    hr = PROBE_DEV->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, __uuidof(ID3D12CommandAllocator),
        reinterpret_cast<void**>(&alloc));
    PLog("       CreateCommandAllocator hr=0x%08lX", Hr(hr));
    if (alloc != nullptr) {
        alloc->Release();
    }
}

void StepCommittedResources(void* p) {
    D3D12_RESOURCE_DESC rd = {};
    rd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    rd.Width = 65536;
    rd.Height = 1;
    rd.DepthOrArraySize = 1;
    rd.MipLevels = 1;
    rd.Format = DXGI_FORMAT_UNKNOWN;
    rd.SampleDesc.Count = 1;
    rd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    static const D3D12_HEAP_TYPE kHeaps[] = {D3D12_HEAP_TYPE_UPLOAD, D3D12_HEAP_TYPE_DEFAULT, D3D12_HEAP_TYPE_READBACK};
    for (D3D12_HEAP_TYPE t : kHeaps) {
        D3D12_HEAP_PROPERTIES hp = {};
        hp.Type = t;
        hp.CreationNodeMask = 1;
        hp.VisibleNodeMask = 1;
        const D3D12_RESOURCE_STATES state = (t == D3D12_HEAP_TYPE_READBACK) ? D3D12_RESOURCE_STATE_COPY_DEST
            : (t == D3D12_HEAP_TYPE_DEFAULT) ? D3D12_RESOURCE_STATE_COMMON : D3D12_RESOURCE_STATE_GENERIC_READ;
        ID3D12Resource* res = nullptr;
        const HRESULT hr = PROBE_DEV->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &rd, state, nullptr,
            __uuidof(ID3D12Resource), reinterpret_cast<void**>(&res));
        PLog("       CreateCommittedResource(heap type %d, 64 KiB buffer) hr=0x%08lX", static_cast<int>(t), Hr(hr));
        if (res != nullptr) {
            res->Release();
        }
    }
    // A render-target texture in a default heap, like Dawn's swapchain/EFB textures.
    D3D12_HEAP_PROPERTIES hp = {};
    hp.Type = D3D12_HEAP_TYPE_DEFAULT;
    hp.CreationNodeMask = 1;
    hp.VisibleNodeMask = 1;
    D3D12_RESOURCE_DESC td = {};
    td.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    td.Width = 640;
    td.Height = 480;
    td.DepthOrArraySize = 1;
    td.MipLevels = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    td.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    D3D12_CLEAR_VALUE cv = {};
    cv.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    ID3D12Resource* tex = nullptr;
    const HRESULT hr = PROBE_DEV->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &td,
        D3D12_RESOURCE_STATE_RENDER_TARGET, &cv, __uuidof(ID3D12Resource), reinterpret_cast<void**>(&tex));
    PLog("       CreateCommittedResource(640x480 RGBA8 render target) hr=0x%08lX", Hr(hr));
    if (tex != nullptr) {
        tex->Release();
    }
}

void StepCommandSignatures(void* p) {
    static const struct {
        D3D12_INDIRECT_ARGUMENT_TYPE type;
        UINT stride;
        const char* name;
    } kSigs[] = {
        {D3D12_INDIRECT_ARGUMENT_TYPE_DISPATCH, 12, "dispatch"},
        {D3D12_INDIRECT_ARGUMENT_TYPE_DRAW, 16, "draw"},
        {D3D12_INDIRECT_ARGUMENT_TYPE_DRAW_INDEXED, 20, "draw indexed"},
    };
    for (const auto& s : kSigs) {
        D3D12_INDIRECT_ARGUMENT_DESC arg = {};
        arg.Type = s.type;
        D3D12_COMMAND_SIGNATURE_DESC cs = {};
        cs.ByteStride = s.stride;
        cs.NumArgumentDescs = 1;
        cs.pArgumentDescs = &arg;
        ID3D12CommandSignature* sig = nullptr;
        const HRESULT hr = PROBE_DEV->CreateCommandSignature(&cs, nullptr, __uuidof(ID3D12CommandSignature),
            reinterpret_cast<void**>(&sig));
        PLog("       CreateCommandSignature(%s) hr=0x%08lX", s.name, Hr(hr));
        if (sig != nullptr) {
            sig->Release();
        }
    }
}

void StepDescriptorHeaps(void* p) {
    static const struct {
        D3D12_DESCRIPTOR_HEAP_TYPE type;
        UINT count;
        D3D12_DESCRIPTOR_HEAP_FLAGS flags;
        const char* name;
    } kHeaps[] = {
        {D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 64, D3D12_DESCRIPTOR_HEAP_FLAG_NONE, "RTV"},
        {D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 64, D3D12_DESCRIPTOR_HEAP_FLAG_NONE, "DSV"},
        {D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 4096, D3D12_DESCRIPTOR_HEAP_FLAG_NONE, "CBV_SRV_UAV cpu 4096"},
        {D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER, 2048, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE, "SAMPLER visible 2048"},
        {D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 65536, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE, "CBV_SRV_UAV visible 65536"},
        {D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 1000000, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE, "CBV_SRV_UAV visible 1000000"},
    };
    for (const auto& h : kHeaps) {
        D3D12_DESCRIPTOR_HEAP_DESC hd = {};
        hd.Type = h.type;
        hd.NumDescriptors = h.count;
        hd.Flags = h.flags;
        ID3D12DescriptorHeap* heap = nullptr;
        const HRESULT hr = PROBE_DEV->CreateDescriptorHeap(&hd, __uuidof(ID3D12DescriptorHeap),
            reinterpret_cast<void**>(&heap));
        PLog("       CreateDescriptorHeap(%s) hr=0x%08lX", h.name, Hr(hr));
        if (heap != nullptr) {
            heap->Release();
        }
    }
}

ID3D12RootSignature* g_rootSig = nullptr;
ID3DBlob* g_vs = nullptr;
ID3DBlob* g_ps = nullptr;
ID3DBlob* g_cs = nullptr;

void StepRootSignature(void* p) {
    D3D12_DESCRIPTOR_RANGE range = {};
    range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_CBV;
    range.NumDescriptors = 1;
    range.OffsetInDescriptorsFromTableStart = D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND;
    D3D12_ROOT_PARAMETER rp = {};
    rp.ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    rp.DescriptorTable.NumDescriptorRanges = 1;
    rp.DescriptorTable.pDescriptorRanges = &range;
    rp.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    D3D12_ROOT_SIGNATURE_DESC rsd = {};
    rsd.NumParameters = 1;
    rsd.pParameters = &rp;
    rsd.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    ID3DBlob* blob = nullptr;
    ID3DBlob* err = nullptr;
    HRESULT hr = D3D12SerializeRootSignature(&rsd, D3D_ROOT_SIGNATURE_VERSION_1_0, &blob, &err);
    PLog("       D3D12SerializeRootSignature hr=0x%08lX", Hr(hr));
    if (err != nullptr) {
        err->Release();
    }
    if (SUCCEEDED(hr) && blob != nullptr) {
        hr = PROBE_DEV->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(),
            __uuidof(ID3D12RootSignature), reinterpret_cast<void**>(&g_rootSig));
        PLog("       CreateRootSignature hr=0x%08lX", Hr(hr));
    }
    if (blob != nullptr) {
        blob->Release();
    }
}

void CompileOne(const char* name, const char* src, const char* target, ID3DBlob** out) {
    ID3DBlob* err = nullptr;
    const HRESULT hr = D3DCompile(src, strlen(src), name, nullptr, nullptr, "main", target, 0, 0, out, &err);
    PLog("       D3DCompile(%s, %s) hr=0x%08lX", name, target, Hr(hr));
    if (err != nullptr) {
        PLog("       %s", static_cast<const char*>(err->GetBufferPointer()));
        err->Release();
    }
}

void StepCompileShaders(void*) {
    CompileOne("probe_vs",
        "float4 main(uint id : SV_VertexID) : SV_Position {"
        " float2 p = float2((id << 1) & 2, id & 2); return float4(p * 2.0 - 1.0, 0.0, 1.0); }",
        "vs_5_0", &g_vs);
    CompileOne("probe_ps", "float4 main() : SV_Target { return float4(1.0, 0.0, 0.0, 1.0); }", "ps_5_0", &g_ps);
    CompileOne("probe_cs", "[numthreads(1, 1, 1)] void main() {}", "cs_5_0", &g_cs);
}

void StepGraphicsPipeline(void* p) {
    if (g_rootSig == nullptr || g_vs == nullptr || g_ps == nullptr) {
        PLog("       skipped (no root signature or shaders)");
        return;
    }
    D3D12_GRAPHICS_PIPELINE_STATE_DESC d = {};
    d.pRootSignature = g_rootSig;
    d.VS.pShaderBytecode = g_vs->GetBufferPointer();
    d.VS.BytecodeLength = g_vs->GetBufferSize();
    d.PS.pShaderBytecode = g_ps->GetBufferPointer();
    d.PS.BytecodeLength = g_ps->GetBufferSize();
    d.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    d.SampleMask = UINT_MAX;
    d.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    d.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    d.RasterizerState.DepthClipEnable = TRUE;
    d.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    d.NumRenderTargets = 1;
    d.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    d.SampleDesc.Count = 1;
    ID3D12PipelineState* pso = nullptr;
    const HRESULT hr = PROBE_DEV->CreateGraphicsPipelineState(&d, __uuidof(ID3D12PipelineState),
        reinterpret_cast<void**>(&pso));
    PLog("       CreateGraphicsPipelineState hr=0x%08lX", Hr(hr));
    if (pso != nullptr) {
        pso->Release();
    }
}

void StepComputePipeline(void* p) {
    if (g_rootSig == nullptr || g_cs == nullptr) {
        PLog("       skipped (no root signature or shader)");
        return;
    }
    D3D12_COMPUTE_PIPELINE_STATE_DESC d = {};
    d.pRootSignature = g_rootSig;
    d.CS.pShaderBytecode = g_cs->GetBufferPointer();
    d.CS.BytecodeLength = g_cs->GetBufferSize();
    ID3D12PipelineState* pso = nullptr;
    const HRESULT hr = PROBE_DEV->CreateComputePipelineState(&d, __uuidof(ID3D12PipelineState),
        reinterpret_cast<void**>(&pso));
    PLog("       CreateComputePipelineState hr=0x%08lX", Hr(hr));
    if (pso != nullptr) {
        pso->Release();
    }
}

struct Step {
    const char* name;
    ProbeFn fn;
};

const Step kSteps[] = {
    // Dawn: GatherDeviceInfo (d3d12/D3D12Info.cpp), same order
    {"CheckFeatureSupport(ARCHITECTURE)", StepArchitecture},
    {"CheckFeatureSupport(D3D12_OPTIONS)", StepOptions},
    {"CheckFeatureSupport(D3D12_OPTIONS2)", StepOptions2},
    {"CheckFeatureSupport(D3D12_OPTIONS3)", StepOptions3},
    {"CheckFeatureSupport(D3D12_OPTIONS4)", StepOptions4},
    {"CheckFeatureSupport(D3D12_OPTIONS7)", StepOptions7},
    {"CheckFeatureSupport(D3D12_OPTIONS8)", StepOptions8},
    {"CheckFeatureSupport(D3D12_OPTIONS13)", StepOptions13},
    {"CheckFeatureSupport(D3D12_OPTIONS18 = 47)", StepOptions18},
    {"CheckFeatureSupport(ROOT_SIGNATURE)", StepRootSignatureFeature},
    {"CheckFeatureSupport(EXISTING_HEAPS)", StepExistingHeaps},
    {"CheckFeatureSupport(SHADER_MODEL loop)", StepShaderModels},
    // Dawn: PhysicalDevice / adapter
    {"CheckFeatureSupport(FEATURE_LEVELS)", StepFeatureLevels},
    {"CheckFeatureSupport(FORMAT_SUPPORT)", StepFormatSupport},
    {"CheckFeatureSupport(ARCHITECTURE1)", StepArchitecture1},
    {"CreateCommandQueue + GetTimestampFrequency", StepQueue},
    // Dawn: Device::Initialize and first resources / pipelines
    {"CreateFence + CreateCommandAllocator", StepFenceAndAllocator},
    {"CreateCommittedResource (buffers, render target)", StepCommittedResources},
    {"CreateCommandSignature x3", StepCommandSignatures},
    {"CreateDescriptorHeap x6", StepDescriptorHeaps},
    {"Root signature (serialize + create)", StepRootSignature},
    {"D3DCompile vs/ps/cs 5.0", StepCompileShaders},
    {"CreateGraphicsPipelineState", StepGraphicsPipeline},
    {"CreateComputePipelineState", StepComputePipeline},
};

void NarrowName(const WCHAR* wide, char* out, int outSize) {
    out[0] = '\0';
    WideCharToMultiByte(CP_UTF8, 0, wide, -1, out, outSize, nullptr, nullptr);
    out[outSize - 1] = '\0';
}

}  // namespace

// Result bits.
//   1: a hardware adapter created a D3D12 device (feature level 11_0) without a crash
//   2: a hardware adapter offers a D3D11 device with feature level >= 11.0 (what Dawn's D3D11 needs)
//   4: the probe could not run at all (no DXGI factory); callers should not act on bits 1/2
// Crashes in the later D3D12 steps are only logged ("deep crash"); they do not clear bit 1, so that
// Aurora still runs and the real behaviour can be compared with the probe log.
int dusk_xbox_probe_graphics(const wchar_t* dir) {
    std::filesystem::path path = (dir != nullptr) ? std::filesystem::path(dir) : std::filesystem::path();
    path /= L"gfx-probe.log";
    if (_wfopen_s(&g_probeLog, path.c_str(), L"w") != 0) {
        g_probeLog = nullptr;
    }

    PLog("=== Dusklight Xbox graphics probe (v2: mirrors Dawn's D3D12 initialisation) ===");
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
    bool deepCrash = false;
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

        // ---- D3D12 (hardware adapters only; stop after the first crash in device creation) ----
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
                        result |= 1;
                        for (const Step& s : kSteps) {
                            PLog("  [%s]", s.name);
                            if (!RunGuarded(s.name, s.fn, cr.dev)) {
                                deepCrash = true;
                            }
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
    PLog("=== probe result: d3d12=%s d3d11_fl11=%s d3d12_device_creation_crashed=%s deep_step_crashed=%s ===",
        (result & 1) ? "ok" : "no", (result & 2) ? "ok" : "no", d3d12Crashed ? "YES" : "no",
        deepCrash ? "YES" : "no");
    if (g_probeLog != nullptr) {
        fclose(g_probeLog);
        g_probeLog = nullptr;
    }
    return result;
}
