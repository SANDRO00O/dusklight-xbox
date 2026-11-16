// UWP (Xbox) file picker + disc image access. Part of the Xbox port, see docs/xbox-port.md.
//
// Why: the SDL3-uwp fork's SDL_ShowOpenFileDialog runs a FileOpenPicker from a helper thread, only
// supports one hard-coded setup, swallows every error and returns the picked file's path without
// checking that the app can open it. On the console pressing "Select Disc Image" did nothing. This file
// is called from borealis' file_select.cpp (patched in Apply-Patches.ps1) instead of SDL.
//
// FOUND ON HARDWARE (builds 97e2887f, deb17009): a file picked on a USB drive comes back as
// 'E:\...\game.iso', but opening that path with Win32 fails with ERROR_ACCESS_DENIED (5), and the
// 1 GB image cannot be copied into the app's storage (quota: "The disk is full"). The broker does grant
// access through the StorageFile object, so:
//   * when the path cannot be opened directly, the StorageFile is remembered (and stored in the
//     FutureAccessList under the token "disc", metadata = the path, so it survives a restart);
//   * IStorageItemHandleAccess::Create turns the StorageFile into a real Win32 HANDLE;
//   * dusk_xbox_open_disc_stream(path) wraps that HANDLE into an SDL_IOStream. Aurora's
//     aurora_dvd_open (lib/dolphin/dvd/dvd.cpp) and borealis' io::open (src/io.cpp) call it before
//     falling back to SDL_IOFromFile (both patched in Apply-Patches-Disc.ps1), so the disc verification
//     and the game itself read the image in place;
//   * dusk_xbox_is_picked_path(path) lets borealis' io::check report that file as existing.
// Every step is logged to <LocalState>\TwilitRealm\Dusklight\picker.log.
//
// Build 1c7ce4d8 log: "IStorageItemHandleAccess not available (0x80004002)" = E_NOINTERFACE, because the
// IID below was wrong (the correct one is 5CA296B2-2C25-4D22-B785-B885C8201E6A, see
// https://learn.microsoft.com/windows/win32/api/windowsstoragecom/nn-windowsstoragecom-istorageitemhandleaccess).
//
//   void dusk_xbox_pick_file(void (*done)(void* userdata, const char* utf8Path, const char* error),
//                            void* userdata);
// `done` is called exactly once, possibly on another thread: path set = selected, path null and error
// null = cancelled, path null and error set = failed.

#include <windows.h>

#include <SDL3/SDL_error.h>
#include <SDL3/SDL_iostream.h>

#include <winrt/base.h>
#include <winrt/Windows.ApplicationModel.Core.h>
#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.AccessCache.h>
#include <winrt/Windows.Storage.Pickers.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.UI.Core.h>

#include <algorithm>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>

namespace {

namespace wf = winrt::Windows::Foundation;
namespace ws = winrt::Windows::Storage;
namespace wp = winrt::Windows::Storage::Pickers;
namespace wsa = winrt::Windows::Storage::AccessCache;

using DoneFn = void (*)(void*, const char*, const char*);

std::mutex g_logMutex;

void Log(const char* fmt, ...) {
    std::lock_guard<std::mutex> lock(g_logMutex);
    // Resolved once, on a throw-away MTA thread, so it works from any caller thread (the game calls this
    // file from threads that never initialised COM).
    static const std::wstring path = [] {
        std::wstring result;
        std::thread t([&result] {
            bool inited = false;
            try {
                winrt::init_apartment(winrt::apartment_type::multi_threaded);
                inited = true;
            } catch (...) {
            }
            try {
                result = std::wstring(ws::ApplicationData::Current().LocalFolder().Path().c_str()) +
                         L"\\TwilitRealm\\Dusklight\\picker.log";
            } catch (...) {
            }
            if (inited) {
                winrt::uninit_apartment();
            }
        });
        t.join();
        return result;
    }();
    if (path.empty()) {
        return;
    }
    FILE* f = _wfopen(path.c_str(), L"a");
    if (f == nullptr) {
        return;
    }
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    buf[sizeof(buf) - 1] = '\0';
    fprintf(f, "[%8llu ms] %s\n", static_cast<unsigned long long>(GetTickCount64()), buf);
    fclose(f);
}

void Finish(DoneFn done, void* userdata, const std::string& path, const std::string& error) {
    Log("finish: path='%s' error='%s'", path.c_str(), error.c_str());
    done(userdata, path.empty() ? nullptr : path.c_str(), error.empty() ? nullptr : error.c_str());
}

// Runs `f` on a fresh MTA thread and waits for it (WinRT/COM calls that block must not run on the UI
// thread, and the threads the game calls from may not have COM initialised).
template <class F>
void RunMta(F&& f) {
    std::thread t([&f]() {
        bool inited = false;
        try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
            inited = true;
        } catch (...) {
        }
        try {
            f();
        } catch (...) {
        }
        if (inited) {
            winrt::uninit_apartment();
        }
    });
    t.join();
}

bool CanOpen(const wchar_t* path, DWORD* error) {
    CREATEFILE2_EXTENDED_PARAMETERS params{};
    params.dwSize = sizeof(params);
    params.dwFileAttributes = FILE_ATTRIBUTE_NORMAL;
    HANDLE h = CreateFile2(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, OPEN_EXISTING, &params);
    if (h == INVALID_HANDLE_VALUE) {
        *error = GetLastError();
        return false;
    }
    CloseHandle(h);
    return true;
}

// ---- StorageFile -> HANDLE ----------------------------------------------------------------------

// IStorageItemHandleAccess (windowsstoragecom.h, desktop partition only, so declared here under another
// name). Only the IID and the vtable layout matter.
const GUID kIidStorageItemHandleAccess = {
    0x5CA296B2, 0x2C25, 0x4D22, {0xB7, 0x85, 0xB8, 0x85, 0xC8, 0x20, 0x1E, 0x6A}};

struct IDuskStorageItemHandleAccess : IUnknown {
    virtual HRESULT STDMETHODCALLTYPE Create(UINT32 accessOptions, UINT32 sharingOptions, UINT32 options,
                                             IUnknown* oplockBreakingHandler, HANDLE* interopHandle) = 0;
};

constexpr UINT32 kHaoRead = 0x120089;          // HAO_READ
constexpr UINT32 kHsoShareRead = 0x1;          // HSO_SHARE_READ
constexpr UINT32 kHoRandomAccess = 0x10000000; // HO_RANDOM_ACCESS

// Returns a Win32 HANDLE for the file (caller closes it) or nullptr, with a message in `*err`.
HANDLE HandleFromStorageFile(ws::StorageFile const& file, std::string* err) {
    try {
        winrt::com_ptr<IDuskStorageItemHandleAccess> access;
        IUnknown* unk = reinterpret_cast<IUnknown*>(winrt::get_abi(file));
        HRESULT hr = unk->QueryInterface(kIidStorageItemHandleAccess, access.put_void());
        if (FAILED(hr)) {
            char b[96];
            snprintf(b, sizeof(b), "IStorageItemHandleAccess not available (0x%08lx)", static_cast<unsigned long>(hr));
            *err = b;
            return nullptr;
        }
        HANDLE h = nullptr;
        hr = access->Create(kHaoRead, kHsoShareRead, kHoRandomAccess, nullptr, &h);
        if (FAILED(hr) || h == nullptr || h == INVALID_HANDLE_VALUE) {
            char b[96];
            snprintf(b, sizeof(b), "IStorageItemHandleAccess::Create failed (0x%08lx)", static_cast<unsigned long>(hr));
            *err = b;
            return nullptr;
        }
        return h;
    } catch (winrt::hresult_error const& e) {
        *err = "handle access exception: " + winrt::to_string(e.message());
        return nullptr;
    } catch (...) {
        *err = "handle access unknown exception";
        return nullptr;
    }
}

// ---- remembered disc ----------------------------------------------------------------------------

std::mutex g_stateMutex;
std::string g_knownPath; // path of the picked disc that is only reachable through its StorageFile
ws::StorageFile g_knownFile{nullptr};
std::once_flag g_loadOnce;

void LoadPersisted() {
    std::call_once(g_loadOnce, [] {
        RunMta([] {
            try {
                auto list = wsa::StorageApplicationPermissions::FutureAccessList();
                // AccessListEntry is a struct with the fields Token and Metadata (not methods).
                for (auto const& entry : list.Entries()) {
                    if (entry.Token == L"disc") {
                        std::lock_guard<std::mutex> lock(g_stateMutex);
                        if (g_knownPath.empty()) {
                            g_knownPath = winrt::to_string(entry.Metadata);
                        }
                        break;
                    }
                }
            } catch (winrt::hresult_error const& e) {
                Log("reading the future access list failed: %s", winrt::to_string(e.message()).c_str());
            }
        });
        std::string known;
        {
            std::lock_guard<std::mutex> lock(g_stateMutex);
            known = g_knownPath;
        }
        Log("persisted disc path: '%s'", known.c_str());
    });
}

bool IsKnownPath(const char* utf8Path) {
    if (utf8Path == nullptr || utf8Path[0] == '\0') {
        return false;
    }
    LoadPersisted();
    std::lock_guard<std::mutex> lock(g_stateMutex);
    return !g_knownPath.empty() && _stricmp(g_knownPath.c_str(), utf8Path) == 0;
}

// Must run on an MTA thread.
HANDLE OpenKnownHandle(std::string* err) {
    ws::StorageFile file{nullptr};
    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        file = g_knownFile;
    }
    if (!file) {
        try {
            file = wsa::StorageApplicationPermissions::FutureAccessList().GetFileAsync(L"disc").get();
        } catch (winrt::hresult_error const& e) {
            *err = "FutureAccessList.GetFileAsync failed: " + winrt::to_string(e.message());
            return nullptr;
        }
        std::lock_guard<std::mutex> lock(g_stateMutex);
        g_knownFile = file;
    }
    return HandleFromStorageFile(file, err);
}

// ---- SDL_IOStream over the HANDLE ---------------------------------------------------------------

struct DiscIo {
    HANDLE handle = nullptr;
    int64_t size = 0;
    int64_t pos = 0;
};

Sint64 SDLCALL DiscIoSize(void* userdata) {
    return static_cast<DiscIo*>(userdata)->size;
}

Sint64 SDLCALL DiscIoSeek(void* userdata, Sint64 offset, SDL_IOWhence whence) {
    auto* io = static_cast<DiscIo*>(userdata);
    int64_t base = 0;
    switch (whence) {
    case SDL_IO_SEEK_SET:
        base = 0;
        break;
    case SDL_IO_SEEK_CUR:
        base = io->pos;
        break;
    case SDL_IO_SEEK_END:
        base = io->size;
        break;
    default:
        SDL_SetError("Unknown seek origin");
        return -1;
    }
    const int64_t target = base + offset;
    if (target < 0) {
        SDL_SetError("Seek before the start of the disc image");
        return -1;
    }
    io->pos = target;
    return target;
}

size_t SDLCALL DiscIoRead(void* userdata, void* ptr, size_t size, SDL_IOStatus* status) {
    auto* io = static_cast<DiscIo*>(userdata);
    auto* out = static_cast<uint8_t*>(ptr);
    size_t total = 0;
    while (total < size) {
        const DWORD chunk = static_cast<DWORD>(std::min<size_t>(size - total, 1u << 30));
        const uint64_t offset = static_cast<uint64_t>(io->pos) + total;
        OVERLAPPED ov{};
        ov.Offset = static_cast<DWORD>(offset);
        ov.OffsetHigh = static_cast<DWORD>(offset >> 32);
        DWORD got = 0;
        if (!ReadFile(io->handle, out + total, chunk, &got, &ov)) {
            const DWORD error = GetLastError();
            if (error == ERROR_HANDLE_EOF) {
                *status = SDL_IO_STATUS_EOF;
            } else {
                SDL_SetError("ReadFile failed (Windows error %lu)", static_cast<unsigned long>(error));
                *status = SDL_IO_STATUS_ERROR;
            }
            break;
        }
        if (got == 0) {
            *status = SDL_IO_STATUS_EOF;
            break;
        }
        total += got;
    }
    io->pos += static_cast<int64_t>(total);
    return total;
}

size_t SDLCALL DiscIoWrite(void*, const void*, size_t, SDL_IOStatus* status) {
    SDL_SetError("The disc image is read-only");
    *status = SDL_IO_STATUS_READONLY;
    return 0;
}

bool SDLCALL DiscIoClose(void* userdata) {
    auto* io = static_cast<DiscIo*>(userdata);
    if (io->handle != nullptr) {
        CloseHandle(io->handle);
    }
    delete io;
    return true;
}

// ---- manifest diagnostics -----------------------------------------------------------------------

void LogInstalledManifest() {
    try {
        const std::wstring path =
            std::wstring(winrt::Windows::ApplicationModel::Package::Current().InstalledLocation().Path().c_str()) +
            L"\\AppxManifest.xml";
        FILE* f = _wfopen(path.c_str(), L"rb");
        if (f == nullptr) {
            Log("installed manifest: could not open");
            return;
        }
        std::string text;
        char buf[4096];
        size_t n;
        while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
            text.append(buf, n);
        }
        fclose(f);
        auto has = [&](const char* s) { return text.find(s) != std::string::npos; };
        Log("installed manifest: removableStorage=%d broadFileSystemAccess=%d fileTypeAssociation=%d (%zu bytes)",
            has("removableStorage"), has("broadFileSystemAccess"), has("windows.fileTypeAssociation"), text.size());
    } catch (...) {
        Log("installed manifest: exception while reading");
    }
}

// ---- picker -------------------------------------------------------------------------------------

void HandlePicked(DoneFn done, void* userdata, ws::StorageFile file) {
    try {
        if (!file) {
            Log("picker returned no file (cancelled)");
            Finish(done, userdata, "", "");
            return;
        }
        const std::string path = winrt::to_string(file.Path());
        Log("picked '%s'", path.c_str());
        DWORD error = 0;
        if (!path.empty() && CanOpen(file.Path().c_str(), &error)) {
            Log("path is directly readable");
            Finish(done, userdata, path, "");
            return;
        }
        Log("path not directly readable (win32 error %lu), using the StorageFile handle", error);
        LogInstalledManifest();
        std::thread([done, userdata, file, path, error]() {
            try {
                winrt::init_apartment(winrt::apartment_type::multi_threaded);
                {
                    std::lock_guard<std::mutex> lock(g_stateMutex);
                    g_knownPath = path;
                    g_knownFile = file;
                }
                try {
                    wsa::StorageApplicationPermissions::FutureAccessList().AddOrReplace(L"disc", file, file.Path());
                    Log("stored in the future access list");
                } catch (winrt::hresult_error const& e) {
                    Log("future access list failed (the selection will not survive a restart): %s",
                        winrt::to_string(e.message()).c_str());
                }
                std::string err;
                HANDLE h = HandleFromStorageFile(file, &err);
                if (h == nullptr) {
                    Log("handle test failed: %s", err.c_str());
                    Finish(done, userdata, "",
                           "The game cannot read this file (Windows error " + std::to_string(error) + "; " + err + ")");
                    return;
                }
                LARGE_INTEGER size{};
                GetFileSizeEx(h, &size);
                Log("handle test ok, size %lld bytes", static_cast<long long>(size.QuadPart));
                CloseHandle(h);
                Finish(done, userdata, path, "");
            } catch (winrt::hresult_error const& e) {
                Finish(done, userdata, "", "Opening the selected file failed: " + winrt::to_string(e.message()));
            } catch (...) {
                Finish(done, userdata, "", "Opening the selected file failed");
            }
        }).detach();
    } catch (winrt::hresult_error const& e) {
        Finish(done, userdata, "", "Handling the selected file failed: " + winrt::to_string(e.message()));
    } catch (...) {
        Finish(done, userdata, "", "Handling the selected file failed");
    }
}

// Must run on the UI thread.
void StartPick(DoneFn done, void* userdata) {
    wp::FileOpenPicker picker;
    try {
        picker.ViewMode(wp::PickerViewMode::List);
    } catch (...) {
        Log("ViewMode failed (ignored)");
    }
    try {
        picker.FileTypeFilter().Append(L"*");
    } catch (...) {
        Log("'*' filter rejected, using the disc image extensions");
        for (const wchar_t* ext : {L".iso", L".gcm", L".ciso", L".gcz", L".nfs", L".rvz", L".wbfs", L".wia", L".tgc"}) {
            picker.FileTypeFilter().Append(ext);
        }
    }
    Log("calling PickSingleFileAsync");
    auto op = picker.PickSingleFileAsync();
    op.Completed([done, userdata](wf::IAsyncOperation<ws::StorageFile> const& info, wf::AsyncStatus status) {
        try {
            Log("picker completed, status=%d", static_cast<int>(status));
            if (status != wf::AsyncStatus::Completed) {
                Finish(done, userdata, "", status == wf::AsyncStatus::Canceled ? "" : "The file picker failed");
                return;
            }
            HandlePicked(done, userdata, info.GetResults());
        } catch (winrt::hresult_error const& e) {
            Finish(done, userdata, "", "The file picker failed: " + winrt::to_string(e.message()));
        } catch (...) {
            Finish(done, userdata, "", "The file picker failed");
        }
    });
}

} // namespace

// Returns an SDL_IOStream reading the picked disc through its StorageFile, or nullptr when `utf8Path` is
// not a file that needed that (callers then fall back to SDL_IOFromFile).
extern "C" SDL_IOStream* dusk_xbox_open_disc_stream(const char* utf8Path) {
    if (!IsKnownPath(utf8Path)) {
        return nullptr;
    }
    HANDLE h = nullptr;
    std::string err;
    RunMta([&] { h = OpenKnownHandle(&err); });
    if (h == nullptr) {
        Log("open_disc_stream('%s'): no handle: %s", utf8Path, err.c_str());
        return nullptr;
    }
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(h, &size)) {
        Log("open_disc_stream('%s'): GetFileSizeEx failed (%lu)", utf8Path, GetLastError());
        CloseHandle(h);
        return nullptr;
    }
    auto* io = new DiscIo{h, size.QuadPart, 0};
    SDL_IOStreamInterface iface;
    SDL_INIT_INTERFACE(&iface);
    iface.size = DiscIoSize;
    iface.seek = DiscIoSeek;
    iface.read = DiscIoRead;
    iface.write = DiscIoWrite;
    iface.close = DiscIoClose;
    SDL_IOStream* stream = SDL_OpenIO(&iface, io);
    if (stream == nullptr) {
        Log("open_disc_stream('%s'): SDL_OpenIO failed: %s", utf8Path, SDL_GetError());
        DiscIoClose(io);
        return nullptr;
    }
    Log("open_disc_stream('%s'): ok, %lld bytes", utf8Path, static_cast<long long>(size.QuadPart));
    return stream;
}

extern "C" bool dusk_xbox_is_picked_path(const char* utf8Path) {
    return IsKnownPath(utf8Path);
}

extern "C" void dusk_xbox_pick_file(DoneFn done, void* userdata) {
    Log("dusk_xbox_pick_file called");
    try {
        auto dispatcher = winrt::Windows::ApplicationModel::Core::CoreApplication::MainView().CoreWindow().Dispatcher();
        if (dispatcher.HasThreadAccess()) {
            Log("on the UI thread, starting directly");
            StartPick(done, userdata);
            return;
        }
        Log("not on the UI thread, dispatching");
        dispatcher.RunAsync(winrt::Windows::UI::Core::CoreDispatcherPriority::Normal, [done, userdata]() {
            try {
                StartPick(done, userdata);
            } catch (winrt::hresult_error const& e) {
                Finish(done, userdata, "", "Could not open the file picker: " + winrt::to_string(e.message()));
            } catch (...) {
                Finish(done, userdata, "", "Could not open the file picker");
            }
        });
    } catch (winrt::hresult_error const& e) {
        Finish(done, userdata, "", "Could not open the file picker: " + winrt::to_string(e.message()));
    } catch (...) {
        Finish(done, userdata, "", "Could not open the file picker");
    }
}
