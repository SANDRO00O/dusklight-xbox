// Xbox (UWP) graphics probe, part 2. Compiled into the dusklight target next to xbox_gfx_probe.cpp.
//
// Part 1 (xbox_gfx_probe.cpp) showed that the Xbox One S D3D12 driver accepts everything Dawn asks
// while it creates the adapter (device, all CheckFeatureSupport queries, queue, fence, small buffers,
// descriptor heaps, root signature, PSOs), yet the game still dies with EXCEPTION_ACCESS_VIOLATION
// inside umd12ddi.dll (always the same rva 0x73500). The fault address is always a 2 MiB aligned
// address about 60 MiB above the D3D12 device object, and Aurora allocates 5 staging buffers of
// 63 MiB each (lib/gfx/resources.hpp + frame.hpp) right after the device exists. So part 2 tests what
// Aurora/Dawn do next, one step at a time, every step logged and flushed before it runs and run under
// SEH, appended to the same gfx-probe.log:
//   * buffers of growing size (1..256 MiB) in upload / default / readback heaps, mapped and touched
//   * Aurora's exact allocation pattern (5 x 63 MiB upload buffers kept alive + the shared buffers)
//   * custom heaps (CPU page property write-combine / write-back, pool L0), which Dawn uses on UMA
//   * explicit heaps + placed resources
//   * descriptor writes (CBV/SRV/UAV/sampler/RTV, copy, first and last slot of big heaps)
//   * recording and executing a command list and waiting on a fence

#include <windows.h>
#include <d3d12.h>
#include <dxgi.h>

#include <cfloat>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <filesystem>

#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3d12.lib")

int dusk_xbox_probe_graphics(const wchar_t* dir);

namespace {

FILE* g_log = nullptr;

void PLog(const char* fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    buf[sizeof(buf) - 1] = '\0';
    if (g_log != nullptr) {
        fputs(buf, g_log);
        fputc('\n', g_log);
        fflush(g_log);
    }
}

unsigned long Hr(HRESULT hr) {
    return static_cast<unsigned long>(hr);
}

using ProbeFn = void (*)(void*);

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

struct FactoryCtx {
    IDXGIFactory1* factory;
    HRESULT hr;
};

void CreateFactoryFn(void* p) {
    auto* c = static_cast<FactoryCtx*>(p);
    c->hr = CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void**>(&c->factory));
}

struct DeviceCtx {
    IUnknown* adapter;
    ID3D12Device* dev;
    HRESULT hr;
};

void CreateDeviceFn(void* p) {
    auto* c = static_cast<DeviceCtx*>(p);
    c->hr = D3D12CreateDevice(c->adapter, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device),
        reinterpret_cast<void**>(&c->dev));
}

#define PROBE_DEV static_cast<ID3D12Device*>(p)

constexpr UINT64 kMiB = 1024ull * 1024ull;

D3D12_HEAP_PROPERTIES HeapProps(D3D12_HEAP_TYPE type) {
    D3D12_HEAP_PROPERTIES hp = {};
    hp.Type = type;
    hp.CreationNodeMask = 1;
    hp.VisibleNodeMask = 1;
    return hp;
}

D3D12_HEAP_PROPERTIES CustomHeapProps(D3D12_CPU_PAGE_PROPERTY cpu) {
    D3D12_HEAP_PROPERTIES hp = {};
    hp.Type = D3D12_HEAP_TYPE_CUSTOM;
    hp.CPUPageProperty = cpu;
    hp.MemoryPoolPreference = D3D12_MEMORY_POOL_L0;
    hp.CreationNodeMask = 1;
    hp.VisibleNodeMask = 1;
    return hp;
}

D3D12_RESOURCE_DESC BufferDesc(UINT64 bytes, D3D12_RESOURCE_FLAGS flags) {
    D3D12_RESOURCE_DESC rd = {};
    rd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    rd.Width = bytes;
    rd.Height = 1;
    rd.DepthOrArraySize = 1;
    rd.MipLevels = 1;
    rd.Format = DXGI_FORMAT_UNKNOWN;
    rd.SampleDesc.Count = 1;
    rd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    rd.Flags = flags;
    return rd;
}

// Writes the first and last byte of a CPU-visible mapped buffer (or reads them for read-back).
void TouchMapped(ID3D12Resource* res, UINT64 bytes, bool write) {
    void* ptr = nullptr;
    const D3D12_RANGE none = {0, 0};
    PLog("         Map");
    const HRESULT hr = res->Map(0, write ? &none : nullptr, &ptr);
    PLog("         Map hr=0x%08lX ptr=%p", Hr(hr), ptr);
    if (FAILED(hr) || ptr == nullptr) {
        return;
    }
    volatile unsigned char* b = static_cast<volatile unsigned char*>(ptr);
    if (write) {
        PLog("         write first byte");
        b[0] = 1;
        PLog("         write middle byte");
        b[bytes / 2] = 2;
        PLog("         write last byte");
        b[bytes - 1] = 3;
    } else {
        PLog("         read first byte");
        const unsigned char a = b[0];
        PLog("         read last byte");
        const unsigned char z = b[bytes - 1];
        PLog("         read ok (%u %u)", static_cast<unsigned>(a), static_cast<unsigned>(z));
    }
    PLog("         touch ok");
    res->Unmap(0, nullptr);
}

// Creates one committed buffer, optionally maps/touches it. Returns the resource (caller releases)
// or nullptr on failure.
ID3D12Resource* TryCommitted(ID3D12Device* d, const D3D12_HEAP_PROPERTIES& hp, UINT64 bytes,
    D3D12_RESOURCE_FLAGS flags, D3D12_RESOURCE_STATES state, bool cpuVisible, bool cpuWrite,
    const char* label) {
    PLog("       [%s] %llu MiB: CreateCommittedResource", label, static_cast<unsigned long long>(bytes / kMiB));
    const D3D12_RESOURCE_DESC rd = BufferDesc(bytes, flags);
    ID3D12Resource* res = nullptr;
    const HRESULT hr = d->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &rd, state, nullptr,
        __uuidof(ID3D12Resource), reinterpret_cast<void**>(&res));
    PLog("         hr=0x%08lX", Hr(hr));
    if (FAILED(hr) || res == nullptr) {
        return nullptr;
    }
    if (cpuVisible) {
        TouchMapped(res, bytes, cpuWrite);
    }
    return res;
}

// ---- steps ----------------------------------------------------------------------------------

void StepBufferLadder(void* p) {
    ID3D12Device* d = PROBE_DEV;
    static const UINT64 kSizes[] = {1, 4, 8, 16, 24, 32, 48, 63, 64, 128, 256};
    static const struct {
        D3D12_HEAP_TYPE type;
        D3D12_RESOURCE_STATES state;
        bool cpu;
        bool write;
        const char* name;
    } kTypes[] = {
        {D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ, true, true, "upload"},
        {D3D12_HEAP_TYPE_DEFAULT, D3D12_RESOURCE_STATE_COMMON, false, false, "default"},
        {D3D12_HEAP_TYPE_READBACK, D3D12_RESOURCE_STATE_COPY_DEST, true, false, "readback"},
    };
    for (const auto& t : kTypes) {
        for (UINT64 mib : kSizes) {
            ID3D12Resource* r = TryCommitted(d, HeapProps(t.type), mib * kMiB, D3D12_RESOURCE_FLAG_NONE,
                t.state, t.cpu, t.write, t.name);
            if (r == nullptr) {
                break;  // larger sizes of this type will not work either
            }
            r->Release();
        }
    }
}

void StepAuroraAllocations(void* p) {
    ID3D12Device* d = PROBE_DEV;
    // lib/gfx/resources.hpp: uniform 24, vertex 5, index 2, storage 8, texture upload 24 MiB per
    // staging buffer; frame.hpp: StagingBufferCount = FrameSlotCount(2) + 3 = 5.
    const UINT64 stagingBytes = (24 + 5 + 2 + 8 + 24) * kMiB;
    ID3D12Resource* staging[5] = {};
    for (int i = 0; i < 5; ++i) {
        char label[32];
        snprintf(label, sizeof(label), "staging %d", i);
        staging[i] = TryCommitted(d, HeapProps(D3D12_HEAP_TYPE_UPLOAD), stagingBytes, D3D12_RESOURCE_FLAG_NONE,
            D3D12_RESOURCE_STATE_GENERIC_READ, true, true, label);
    }
    ID3D12Resource* gpu[4] = {};
    gpu[0] = TryCommitted(d, HeapProps(D3D12_HEAP_TYPE_DEFAULT), 24 * kMiB, D3D12_RESOURCE_FLAG_NONE,
        D3D12_RESOURCE_STATE_COMMON, false, false, "shared uniform");
    gpu[1] = TryCommitted(d, HeapProps(D3D12_HEAP_TYPE_DEFAULT), 5 * kMiB, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
        D3D12_RESOURCE_STATE_COMMON, false, false, "shared vertex (storage)");
    gpu[2] = TryCommitted(d, HeapProps(D3D12_HEAP_TYPE_DEFAULT), 2 * kMiB, D3D12_RESOURCE_FLAG_NONE,
        D3D12_RESOURCE_STATE_COMMON, false, false, "shared index");
    gpu[3] = TryCommitted(d, HeapProps(D3D12_HEAP_TYPE_DEFAULT), 8 * kMiB, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
        D3D12_RESOURCE_STATE_COMMON, false, false, "shared storage");
    for (ID3D12Resource* r : gpu) {
        if (r != nullptr) {
            r->Release();
        }
    }
    for (ID3D12Resource* r : staging) {
        if (r != nullptr) {
            r->Release();
        }
    }
}

void StepCustomHeaps(void* p) {
    ID3D12Device* d = PROBE_DEV;
    static const UINT64 kSizes[] = {1, 8, 64};
    static const struct {
        D3D12_CPU_PAGE_PROPERTY cpu;
        D3D12_RESOURCE_STATES state;
        bool write;
        const char* name;
    } kKinds[] = {
        {D3D12_CPU_PAGE_PROPERTY_WRITE_COMBINE, D3D12_RESOURCE_STATE_GENERIC_READ, true, "custom write-combine L0"},
        {D3D12_CPU_PAGE_PROPERTY_WRITE_BACK, D3D12_RESOURCE_STATE_COPY_DEST, true, "custom write-back L0"},
    };
    for (const auto& k : kKinds) {
        for (UINT64 mib : kSizes) {
            ID3D12Resource* r = TryCommitted(d, CustomHeapProps(k.cpu), mib * kMiB, D3D12_RESOURCE_FLAG_NONE,
                k.state, true, k.write, k.name);
            if (r == nullptr) {
                break;
            }
            r->Release();
        }
    }
}

void StepPlacedResources(void* p) {
    ID3D12Device* d = PROBE_DEV;
    static const UINT64 kSizes[] = {4, 8, 16, 64};
    static const struct {
        D3D12_HEAP_TYPE type;
        D3D12_RESOURCE_STATES state;
        bool cpu;
        const char* name;
    } kTypes[] = {
        {D3D12_HEAP_TYPE_DEFAULT, D3D12_RESOURCE_STATE_COMMON, false, "default"},
        {D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ, true, "upload"},
    };
    for (const auto& t : kTypes) {
        for (UINT64 mib : kSizes) {
            PLog("       [heap %s] %llu MiB: CreateHeap", t.name, static_cast<unsigned long long>(mib));
            D3D12_HEAP_DESC hd = {};
            hd.SizeInBytes = mib * kMiB;
            hd.Properties = HeapProps(t.type);
            hd.Alignment = 0;
            hd.Flags = D3D12_HEAP_FLAG_ALLOW_ONLY_BUFFERS;
            ID3D12Heap* heap = nullptr;
            HRESULT hr = d->CreateHeap(&hd, __uuidof(ID3D12Heap), reinterpret_cast<void**>(&heap));
            PLog("         CreateHeap hr=0x%08lX", Hr(hr));
            if (FAILED(hr) || heap == nullptr) {
                break;
            }
            const D3D12_RESOURCE_DESC rd = BufferDesc(mib * kMiB, D3D12_RESOURCE_FLAG_NONE);
            ID3D12Resource* res = nullptr;
            PLog("         CreatePlacedResource");
            hr = d->CreatePlacedResource(heap, 0, &rd, t.state, nullptr, __uuidof(ID3D12Resource),
                reinterpret_cast<void**>(&res));
            PLog("         CreatePlacedResource hr=0x%08lX", Hr(hr));
            if (SUCCEEDED(hr) && res != nullptr) {
                if (t.cpu) {
                    TouchMapped(res, mib * kMiB, true);
                }
                res->Release();
            }
            heap->Release();
        }
    }
}

ID3D12DescriptorHeap* MakeHeap(ID3D12Device* d, D3D12_DESCRIPTOR_HEAP_TYPE type, UINT count, bool visible,
    const char* name) {
    D3D12_DESCRIPTOR_HEAP_DESC hd = {};
    hd.Type = type;
    hd.NumDescriptors = count;
    hd.Flags = visible ? D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE : D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
    ID3D12DescriptorHeap* heap = nullptr;
    const HRESULT hr = d->CreateDescriptorHeap(&hd, __uuidof(ID3D12DescriptorHeap), reinterpret_cast<void**>(&heap));
    PLog("       CreateDescriptorHeap(%s) hr=0x%08lX", name, Hr(hr));
    return SUCCEEDED(hr) ? heap : nullptr;
}

D3D12_CPU_DESCRIPTOR_HANDLE CpuAt(ID3D12DescriptorHeap* h, UINT inc, UINT idx) {
    D3D12_CPU_DESCRIPTOR_HANDLE c = h->GetCPUDescriptorHandleForHeapStart();
    c.ptr += static_cast<SIZE_T>(inc) * idx;
    return c;
}

ID3D12Resource* MakeRenderTarget(ID3D12Device* d) {
    D3D12_HEAP_PROPERTIES hp = HeapProps(D3D12_HEAP_TYPE_DEFAULT);
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
    const HRESULT hr = d->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &td,
        D3D12_RESOURCE_STATE_RENDER_TARGET, &cv, __uuidof(ID3D12Resource), reinterpret_cast<void**>(&tex));
    PLog("       CreateCommittedResource(640x480 RGBA8 render target) hr=0x%08lX", Hr(hr));
    return SUCCEEDED(hr) ? tex : nullptr;
}

void StepDescriptorWrites(void* p) {
    ID3D12Device* d = PROBE_DEV;
    const UINT incView = d->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    const UINT incSampler = d->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER);
    const UINT incRtv = d->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    PLog("       increments: cbv_srv_uav=%u sampler=%u rtv=%u", incView, incSampler, incRtv);

    ID3D12DescriptorHeap* cpuView = MakeHeap(d, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 4096, false, "cpu view 4096");
    ID3D12DescriptorHeap* visView = MakeHeap(d, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 1000000, true, "visible view 1000000");
    ID3D12DescriptorHeap* visSampler = MakeHeap(d, D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER, 2048, true, "visible sampler 2048");
    ID3D12DescriptorHeap* rtv = MakeHeap(d, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 64, false, "rtv 64");
    ID3D12Resource* tex = MakeRenderTarget(d);
    ID3D12Resource* buf = TryCommitted(d, HeapProps(D3D12_HEAP_TYPE_UPLOAD), 64 * 1024, D3D12_RESOURCE_FLAG_NONE,
        D3D12_RESOURCE_STATE_GENERIC_READ, false, false, "cbv buffer");

    if (visView != nullptr && buf != nullptr) {
        D3D12_CONSTANT_BUFFER_VIEW_DESC cbv = {};
        cbv.BufferLocation = buf->GetGPUVirtualAddress();
        cbv.SizeInBytes = 256;
        static const UINT kIdx[] = {0, 1, 999999};
        for (UINT i : kIdx) {
            PLog("       CreateConstantBufferView -> visible view heap slot %u", i);
            d->CreateConstantBufferView(&cbv, CpuAt(visView, incView, i));
            PLog("         ok");
        }
    }
    if (visView != nullptr) {
        D3D12_SHADER_RESOURCE_VIEW_DESC sv = {};
        sv.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        sv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
        sv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        sv.Texture2D.MipLevels = 1;
        PLog("       CreateShaderResourceView(null resource) -> slot 2");
        d->CreateShaderResourceView(nullptr, &sv, CpuAt(visView, incView, 2));
        PLog("         ok");
        if (tex != nullptr) {
            PLog("       CreateShaderResourceView(texture) -> slot 3");
            d->CreateShaderResourceView(tex, &sv, CpuAt(visView, incView, 3));
            PLog("         ok");
        }
        D3D12_UNORDERED_ACCESS_VIEW_DESC uv = {};
        uv.Format = DXGI_FORMAT_R32_UINT;
        uv.ViewDimension = D3D12_UAV_DIMENSION_BUFFER;
        uv.Buffer.NumElements = 1;
        PLog("       CreateUnorderedAccessView(null resource) -> slot 4");
        d->CreateUnorderedAccessView(nullptr, nullptr, &uv, CpuAt(visView, incView, 4));
        PLog("         ok");
    }
    if (visSampler != nullptr) {
        D3D12_SAMPLER_DESC sd = {};
        sd.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
        sd.AddressU = D3D12_TEXTURE_ADDRESS_MODE_WRAP;
        sd.AddressV = D3D12_TEXTURE_ADDRESS_MODE_WRAP;
        sd.AddressW = D3D12_TEXTURE_ADDRESS_MODE_WRAP;
        sd.MaxLOD = FLT_MAX;
        sd.ComparisonFunc = D3D12_COMPARISON_FUNC_NEVER;
        static const UINT kIdx[] = {0, 2047};
        for (UINT i : kIdx) {
            PLog("       CreateSampler -> visible sampler heap slot %u", i);
            d->CreateSampler(&sd, CpuAt(visSampler, incSampler, i));
            PLog("         ok");
        }
    }
    if (rtv != nullptr && tex != nullptr) {
        PLog("       CreateRenderTargetView -> slot 0");
        d->CreateRenderTargetView(tex, nullptr, CpuAt(rtv, incRtv, 0));
        PLog("         ok");
    }
    if (cpuView != nullptr && visView != nullptr && buf != nullptr) {
        D3D12_CONSTANT_BUFFER_VIEW_DESC cbv = {};
        cbv.BufferLocation = buf->GetGPUVirtualAddress();
        cbv.SizeInBytes = 256;
        PLog("       CreateConstantBufferView -> cpu view heap slot 0");
        d->CreateConstantBufferView(&cbv, CpuAt(cpuView, incView, 0));
        PLog("         ok");
        static const UINT kIdx[] = {5, 999999};
        for (UINT i : kIdx) {
            PLog("       CopyDescriptorsSimple cpu slot 0 -> visible view slot %u", i);
            d->CopyDescriptorsSimple(1, CpuAt(visView, incView, i), CpuAt(cpuView, incView, 0),
                D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
            PLog("         ok");
        }
    }
    if (buf != nullptr) buf->Release();
    if (tex != nullptr) tex->Release();
    if (rtv != nullptr) rtv->Release();
    if (visSampler != nullptr) visSampler->Release();
    if (visView != nullptr) visView->Release();
    if (cpuView != nullptr) cpuView->Release();
}

void StepCommandList(void* p) {
    ID3D12Device* d = PROBE_DEV;
    ID3D12CommandQueue* q = nullptr;
    ID3D12CommandAllocator* alloc = nullptr;
    ID3D12GraphicsCommandList* list = nullptr;
    ID3D12Fence* fence = nullptr;

    D3D12_COMMAND_QUEUE_DESC qd = {};
    qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    HRESULT hr = d->CreateCommandQueue(&qd, __uuidof(ID3D12CommandQueue), reinterpret_cast<void**>(&q));
    PLog("       CreateCommandQueue hr=0x%08lX", Hr(hr));
    hr = d->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, __uuidof(ID3D12CommandAllocator),
        reinterpret_cast<void**>(&alloc));
    PLog("       CreateCommandAllocator hr=0x%08lX", Hr(hr));
    if (q == nullptr || alloc == nullptr) {
        goto done;
    }
    hr = d->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, nullptr, __uuidof(ID3D12GraphicsCommandList),
        reinterpret_cast<void**>(&list));
    PLog("       CreateCommandList hr=0x%08lX", Hr(hr));
    hr = d->CreateFence(0, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence), reinterpret_cast<void**>(&fence));
    PLog("       CreateFence hr=0x%08lX", Hr(hr));
    if (list == nullptr || fence == nullptr) {
        goto done;
    }
    {
        ID3D12DescriptorHeap* visView = MakeHeap(d, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 65536, true, "visible view 65536");
        ID3D12DescriptorHeap* visSampler = MakeHeap(d, D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER, 2048, true, "visible sampler 2048");
        ID3D12DescriptorHeap* rtv = MakeHeap(d, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 8, false, "rtv 8");
        ID3D12Resource* tex = MakeRenderTarget(d);
        ID3D12Resource* up = TryCommitted(d, HeapProps(D3D12_HEAP_TYPE_UPLOAD), 64 * 1024, D3D12_RESOURCE_FLAG_NONE,
            D3D12_RESOURCE_STATE_GENERIC_READ, false, false, "upload");
        ID3D12Resource* dst = TryCommitted(d, HeapProps(D3D12_HEAP_TYPE_DEFAULT), 64 * 1024, D3D12_RESOURCE_FLAG_NONE,
            D3D12_RESOURCE_STATE_COMMON, false, false, "default");

        if (visView != nullptr && visSampler != nullptr) {
            ID3D12DescriptorHeap* heaps[2] = {visView, visSampler};
            PLog("       SetDescriptorHeaps");
            list->SetDescriptorHeaps(2, heaps);
            PLog("         ok");
        }
        if (rtv != nullptr && tex != nullptr) {
            const UINT incRtv = d->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
            (void)incRtv;
            const D3D12_CPU_DESCRIPTOR_HANDLE h = rtv->GetCPUDescriptorHandleForHeapStart();
            d->CreateRenderTargetView(tex, nullptr, h);
            const float color[4] = {0.1f, 0.2f, 0.3f, 1.0f};
            PLog("       ClearRenderTargetView");
            list->ClearRenderTargetView(h, color, 0, nullptr);
            PLog("         ok");
            D3D12_RESOURCE_BARRIER b = {};
            b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
            b.Transition.pResource = tex;
            b.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
            b.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
            b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
            PLog("       ResourceBarrier");
            list->ResourceBarrier(1, &b);
            PLog("         ok");
        }
        if (up != nullptr && dst != nullptr) {
            PLog("       CopyBufferRegion");
            list->CopyBufferRegion(dst, 0, up, 0, 4096);
            PLog("         ok");
        }
        PLog("       Close");
        hr = list->Close();
        PLog("         Close hr=0x%08lX", Hr(hr));
        ID3D12CommandList* lists[1] = {list};
        PLog("       ExecuteCommandLists");
        q->ExecuteCommandLists(1, lists);
        PLog("         ok");
        hr = q->Signal(fence, 1);
        PLog("       Signal hr=0x%08lX", Hr(hr));
        HANDLE ev = CreateEventExW(nullptr, nullptr, 0, EVENT_ALL_ACCESS);
        if (ev != nullptr) {
            hr = fence->SetEventOnCompletion(1, ev);
            PLog("       SetEventOnCompletion hr=0x%08lX", Hr(hr));
            const DWORD w = WaitForSingleObjectEx(ev, 5000, FALSE);
            PLog("       wait result=%lu completed=%llu", static_cast<unsigned long>(w),
                static_cast<unsigned long long>(fence->GetCompletedValue()));
            CloseHandle(ev);
        }
        if (dst != nullptr) dst->Release();
        if (up != nullptr) up->Release();
        if (tex != nullptr) tex->Release();
        if (rtv != nullptr) rtv->Release();
        if (visSampler != nullptr) visSampler->Release();
        if (visView != nullptr) visView->Release();
    }
done:
    if (fence != nullptr) fence->Release();
    if (list != nullptr) list->Release();
    if (alloc != nullptr) alloc->Release();
    if (q != nullptr) q->Release();
}

struct Step {
    const char* name;
    ProbeFn fn;
};

const Step kSteps[] = {
    {"Buffers of growing size (upload/default/readback, mapped + touched)", StepBufferLadder},
    {"Aurora allocation pattern (5 x 63 MiB staging + shared buffers)", StepAuroraAllocations},
    {"Custom heaps (write-combine / write-back, pool L0)", StepCustomHeaps},
    {"Explicit heaps + placed resources", StepPlacedResources},
    {"Descriptor writes", StepDescriptorWrites},
    {"Command list: record, execute, wait", StepCommandList},
};

}  // namespace

// Part 1 + part 2. Same result bits as dusk_xbox_probe_graphics (part 1 decides the result; part 2 only
// adds information to gfx-probe.log).
int dusk_xbox_probe_graphics_ex(const wchar_t* dir) {
    const int result = dusk_xbox_probe_graphics(dir);
    if ((result & 1) == 0) {
        return result;
    }

    std::filesystem::path path = (dir != nullptr) ? std::filesystem::path(dir) : std::filesystem::path();
    path /= L"gfx-probe.log";
    if (_wfopen_s(&g_log, path.c_str(), L"a") != 0) {
        g_log = nullptr;
    }
    PLog("");
    PLog("=== part 2: deep D3D12 tests (buffer sizes like Aurora's, heaps, descriptor writes, command list) ===");

    FactoryCtx fc = {};
    fc.hr = E_FAIL;
    if (!RunGuarded("CreateDXGIFactory1", CreateFactoryFn, &fc) || FAILED(fc.hr) || fc.factory == nullptr) {
        PLog("  no DXGI factory, part 2 skipped");
        if (g_log != nullptr) {
            fclose(g_log);
            g_log = nullptr;
        }
        return result;
    }
    for (UINT i = 0; i < 16; ++i) {
        IDXGIAdapter1* ad = nullptr;
        if (FAILED(fc.factory->EnumAdapters1(i, &ad)) || ad == nullptr) {
            break;
        }
        DXGI_ADAPTER_DESC1 desc = {};
        ad->GetDesc1(&desc);
        if ((desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) == 0) {
            DeviceCtx dc = {};
            dc.adapter = ad;
            dc.hr = E_FAIL;
            PLog("  adapter %u: D3D12CreateDevice", i);
            if (RunGuarded("D3D12CreateDevice", CreateDeviceFn, &dc) && SUCCEEDED(dc.hr) && dc.dev != nullptr) {
                for (const Step& s : kSteps) {
                    PLog("  [%s]", s.name);
                    RunGuarded(s.name, s.fn, dc.dev);
                }
                dc.dev->Release();
            } else {
                PLog("  device creation failed hr=0x%08lX", Hr(dc.hr));
            }
            ad->Release();
            break;  // only the first hardware adapter
        }
        ad->Release();
    }
    fc.factory->Release();
    PLog("=== part 2 done ===");
    if (g_log != nullptr) {
        fclose(g_log);
        g_log = nullptr;
    }
    return result;
}
