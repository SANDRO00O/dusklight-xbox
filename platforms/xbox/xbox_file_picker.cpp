// UWP (Xbox) file picker for the disc image. Part of the Xbox port, see docs/xbox-port.md.
//
// Why: the SDL3-uwp fork's SDL_ShowOpenFileDialog runs a FileOpenPicker from a helper thread, only
// supports one hard-coded setup, swallows every error and returns the picked file's path without
// checking that the app can open it. On the console pressing "Select Disc Image" did nothing. This file
// is called from borealis' file_select.cpp (patched in Apply-Patches.ps1) instead of SDL.
//
// Flow: run the picker on the CoreWindow's UI thread -> get the StorageFile -> if CreateFile2 can open
// its path, return that path. That needs the manifest capabilities added by Patch-Manifest.ps1
// (removableStorage + file type associations for the disc extensions): without them a file on a USB
// drive is access-denied (win32 error 5). Otherwise, for SMALL files only, copy the file into
// <LocalState>\discs\ and return the copy's path. A disc image is 1+ GB and copying it fails with
// "The disk is full" (app storage quota), so large files get a clear error instead.
// Every step is logged to <LocalState>\TwilitRealm\Dusklight\picker.log.
//
//   void dusk_xbox_pick_file(void (*done)(void* userdata, const char* utf8Path, const char* error),
//                            void* userdata);
// `done` is called exactly once, possibly on another thread: path set = selected, path null and error
// null = cancelled, path null and error set = failed.

#include <windows.h>

#include <winrt/base.h>
#include <winrt/Windows.ApplicationModel.Core.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.Pickers.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.UI.Core.h>

#include <cstdarg>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>

namespace {

namespace wf = winrt::Windows::Foundation;
namespace ws = winrt::Windows::Storage;
namespace wp = winrt::Windows::Storage::Pickers;

using DoneFn = void (*)(void*, const char*, const char*);

constexpr uint64_t kMaxCopyBytes = 256ull * 1024 * 1024;

std::mutex g_logMutex;

void Log(const char* fmt, ...) {
    std::lock_guard<std::mutex> lock(g_logMutex);
    static const std::wstring path = [] {
        try {
            return std::wstring(ws::ApplicationData::Current().LocalFolder().Path().c_str()) +
                   L"\\TwilitRealm\\Dusklight\\picker.log";
        } catch (...) {
            return std::wstring();
        }
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

void CopyIntoLocalState(DoneFn done, void* userdata, ws::StorageFile file, DWORD openError) {
    std::thread([done, userdata, file, openError]() {
        try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
            uint64_t size = 0;
            try {
                size = file.GetBasicPropertiesAsync().get().Size();
            } catch (...) {
                Log("could not read the file size");
            }
            Log("file size %llu bytes", static_cast<unsigned long long>(size));
            if (size == 0 || size > kMaxCopyBytes) {
                Finish(done, userdata, "",
                       "The game cannot read this file in place (Windows error " + std::to_string(openError) +
                           "; the app lacks access to this location) and it is too large to copy into the "
                           "app's storage.");
                return;
            }
            auto folder = ws::ApplicationData::Current()
                              .LocalFolder()
                              .CreateFolderAsync(L"discs", ws::CreationCollisionOption::OpenIfExists)
                              .get();
            Log("copying '%s' into LocalState\\discs ...", winrt::to_string(file.Name()).c_str());
            auto copied = file.CopyAsync(folder, file.Name(), ws::NameCollisionOption::ReplaceExisting).get();
            Finish(done, userdata, winrt::to_string(copied.Path()), "");
        } catch (winrt::hresult_error const& e) {
            Finish(done, userdata, "",
                   "Copying the disc image into the app's storage failed: " + winrt::to_string(e.message()));
        } catch (...) {
            Finish(done, userdata, "", "Copying the disc image into the app's storage failed");
        }
    }).detach();
}

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
        Log("path not directly readable (win32 error %lu)", error);
        CopyIntoLocalState(done, userdata, file, error);
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
