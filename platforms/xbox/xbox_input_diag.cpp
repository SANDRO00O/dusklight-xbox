// Xbox One (UWP) controller support fix + diagnostics. Part of the Xbox port, see docs/xbox-port.md.
//
// FIX: the SDL3-uwp fork ships with SDL_HINT_JOYSTICK_WGI disabled by default, and its Windows.Gaming.Input
// driver is the only physical-controller driver in the UWP build, so SDL saw 0 joysticks while Windows
// itself reported "Xbox One Game Controller" (input-diag.log of build 31c69b90). The hint is set in
// dusk_xbox_input_diag_start() before Aurora initialises SDL.
//
// DIAGNOSTICS: writes <CachePath>/input-diag.log with:
//   * everything SDL logs (log output redirected, input category at verbose) from before Aurora starts,
//   * every 1.5 s (on change, and every ~30 s regardless): which SDL subsystems are up, the joystick and
//     gamepad lists SDL sees (name, vid/pid, GUID, is-gamepad, mapping),
//   * what Windows.Gaming.Input itself reports (Gamepad / RawGameController lists, button readings),
//     which tells apart "the OS gives the app no controller" from "SDL does not enumerate it".
// Everything runs on a detached background thread and only reads state; it never changes behaviour.
//
// This entry point also starts the crash / hang diagnostics (xbox_crash_diag.cpp -> crash-diag.log), so the
// m_Do_main.cpp patch does not need to change.
//
// Entry point (called from the m_Do_main.cpp patch right before aurora_initialize):
//   void dusk_xbox_input_diag_start(const wchar_t* dir);

#include <SDL3/SDL.h>

#include <windows.h>

#include <atomic>
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>

#if __has_include(<winrt/Windows.Gaming.Input.h>)
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Gaming.Input.h>
#define DUSK_DIAG_HAVE_WINRT_GAMING 1
#else
#define DUSK_DIAG_HAVE_WINRT_GAMING 0
#endif

// xbox_crash_diag.cpp
void dusk_xbox_crash_diag_start(const wchar_t* dir);

namespace {

std::mutex g_mutex;
FILE* g_file = nullptr;
size_t g_bytes = 0;
constexpr size_t kMaxBytes = 4u * 1024u * 1024u;
std::atomic_bool g_started{false};

void Out(const char* fmt, ...) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_file == nullptr || g_bytes > kMaxBytes) {
        return;
    }
    char buf[1536];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    buf[sizeof(buf) - 1] = '\0';
    const int n = fprintf(g_file, "[%8llu ms] %s\n", static_cast<unsigned long long>(GetTickCount64()), buf);
    if (n > 0) {
        g_bytes += static_cast<size_t>(n);
    }
    fflush(g_file);
}

void SDLCALL SdlLogSink(void*, int category, SDL_LogPriority priority, const char* message) {
    Out("[sdl cat=%d prio=%d] %s", category, static_cast<int>(priority), message != nullptr ? message : "(null)");
}

std::string GuidString(SDL_GUID guid) {
    char text[64] = {};
    SDL_GUIDToString(guid, text, sizeof(text));
    return text;
}

// Builds a description of SDL's view; Out()s it when it differs from the last one (or `force`).
void SampleSdl(std::string& last, bool force) {
    std::string state;
    char line[512];

    const SDL_InitFlags init = SDL_WasInit(0);
    snprintf(line, sizeof(line), "SDL_WasInit=0x%08x (events=%d video=%d joystick=%d gamepad=%d haptic=%d sensor=%d)\n",
             static_cast<unsigned>(init), (init & SDL_INIT_EVENTS) != 0, (init & SDL_INIT_VIDEO) != 0,
             (init & SDL_INIT_JOYSTICK) != 0, (init & SDL_INIT_GAMEPAD) != 0, (init & SDL_INIT_HAPTIC) != 0,
             (init & SDL_INIT_SENSOR) != 0);
    state += line;

    if ((init & SDL_INIT_JOYSTICK) != 0) {
        int nj = 0;
        SDL_JoystickID* joys = SDL_GetJoysticks(&nj);
        if (joys == nullptr) {
            snprintf(line, sizeof(line), "SDL_GetJoysticks failed: %s\n", SDL_GetError());
            state += line;
        } else {
            snprintf(line, sizeof(line), "joysticks=%d\n", nj);
            state += line;
            for (int i = 0; i < nj; ++i) {
                const SDL_JoystickID id = joys[i];
                const char* name = SDL_GetJoystickNameForID(id);
                const bool isPad = SDL_IsGamepad(id);
                char* mapping = isPad ? SDL_GetGamepadMappingForID(id) : nullptr;
                snprintf(line, sizeof(line),
                         "  joystick id=%u name='%s' vid=%04x pid=%04x guid=%s is_gamepad=%d type=%d mapping=%s\n",
                         static_cast<unsigned>(id), name != nullptr ? name : "?", SDL_GetJoystickVendorForID(id),
                         SDL_GetJoystickProductForID(id), GuidString(SDL_GetJoystickGUIDForID(id)).c_str(), isPad,
                         static_cast<int>(SDL_GetJoystickTypeForID(id)), mapping != nullptr ? mapping : "(none)");
                state += line;
                if (mapping != nullptr) {
                    SDL_free(mapping);
                }
            }
            SDL_free(joys);
        }
    }

    if ((init & SDL_INIT_GAMEPAD) != 0) {
        int ng = 0;
        SDL_JoystickID* pads = SDL_GetGamepads(&ng);
        if (pads == nullptr) {
            snprintf(line, sizeof(line), "SDL_GetGamepads failed: %s\n", SDL_GetError());
        } else {
            snprintf(line, sizeof(line), "gamepads=%d\n", ng);
            SDL_free(pads);
        }
        state += line;
    }

    if (force || state != last) {
        last = state;
        Out("SDL state:\n%s", state.c_str());
    }
}

#if DUSK_DIAG_HAVE_WINRT_GAMING
using namespace winrt::Windows::Gaming::Input;

void SampleWgi(std::string& last, bool force) {
    std::string state;
    char line[512];
    try {
        auto pads = Gamepad::Gamepads();
        snprintf(line, sizeof(line), "WGI Gamepad::Gamepads().Size()=%u\n", pads.Size());
        state += line;
        for (uint32_t i = 0; i < pads.Size(); ++i) {
            const GamepadReading r = pads.GetAt(i).GetCurrentReading();
            snprintf(line, sizeof(line), "  pad %u buttons=0x%08x LT=%.2f RT=%.2f LX=%.2f LY=%.2f\n", i,
                     static_cast<unsigned>(r.Buttons), r.LeftTrigger, r.RightTrigger, r.LeftThumbstickX,
                     r.LeftThumbstickY);
            state += line;
        }
        auto raws = RawGameController::RawGameControllers();
        snprintf(line, sizeof(line), "WGI RawGameController::RawGameControllers().Size()=%u\n", raws.Size());
        state += line;
        for (uint32_t i = 0; i < raws.Size(); ++i) {
            const auto raw = raws.GetAt(i);
            snprintf(line, sizeof(line), "  raw %u name='%ls' vid=%04x pid=%04x buttons=%d axes=%d\n", i,
                     raw.DisplayName().c_str(), static_cast<unsigned>(raw.HardwareVendorId()),
                     static_cast<unsigned>(raw.HardwareProductId()), raw.ButtonCount(), raw.AxisCount());
            state += line;
        }
    } catch (winrt::hresult_error const& e) {
        snprintf(line, sizeof(line), "WGI exception 0x%08x: %ls\n", static_cast<unsigned>(e.code().value),
                 e.message().c_str());
        state += line;
    } catch (...) {
        state += "WGI unknown exception\n";
    }

    // Button readings change while the user presses things; only report structural changes unless forced.
    std::string structural;
    for (size_t pos = 0; pos < state.size();) {
        const size_t end = state.find('\n', pos);
        const std::string l = state.substr(pos, end == std::string::npos ? std::string::npos : end - pos);
        if (l.rfind("  pad ", 0) != 0) {
            structural += l;
            structural += '\n';
        }
        if (end == std::string::npos) {
            break;
        }
        pos = end + 1;
    }
    if (force || structural != last) {
        last = structural;
        Out("WGI state:\n%s", state.c_str());
    }
}
#endif

void Worker() {
    Out("diag thread started");
#if DUSK_DIAG_HAVE_WINRT_GAMING
    try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        Gamepad::GamepadAdded([](winrt::Windows::Foundation::IInspectable const&, Gamepad const&) {
            Out("WGI event: GamepadAdded");
        });
        Gamepad::GamepadRemoved([](winrt::Windows::Foundation::IInspectable const&, Gamepad const&) {
            Out("WGI event: GamepadRemoved");
        });
        Out("WGI event handlers registered");
    } catch (winrt::hresult_error const& e) {
        Out("WGI init exception 0x%08x: %ls", static_cast<unsigned>(e.code().value), e.message().c_str());
    } catch (...) {
        Out("WGI init unknown exception");
    }
#else
    Out("Windows.Gaming.Input C++/WinRT headers not available in this build");
#endif

    std::string lastSdl;
    std::string lastWgi;
    for (int i = 0; i < 400; ++i) { // ~10 minutes
        std::this_thread::sleep_for(std::chrono::milliseconds(1500));
        const bool force = (i % 20) == 0;
        SampleSdl(lastSdl, force);
#if DUSK_DIAG_HAVE_WINRT_GAMING
        SampleWgi(lastWgi, force);
#endif
    }
    Out("diag thread finished");
}

} // namespace

void dusk_xbox_input_diag_start(const wchar_t* dir) {
    if (g_started.exchange(true)) {
        return;
    }
    // THE FIX (found with input-diag.log, build 31c69b90): the SDL3-uwp fork ships with
    // SDL_HINT_JOYSTICK_WGI disabled by default (its WhatsNew.txt: "SDL_HINT_JOYSTICK_WGI is disabled by
    // default", and SDL_WGI_JoystickInit does `if (!SDL_GetHintBoolean(SDL_HINT_JOYSTICK_WGI, false)) return`).
    // WGI is the only physical-controller driver in the UWP build, so without this SDL never sees a pad
    // even though Windows.Gaming.Input reports "Xbox One Game Controller". Must be set before SDL_Init.
    SDL_SetHint("SDL_JOYSTICK_WGI", "1");
    if (dir == nullptr) {
        return;
    }
    // Crash / hang diagnostics (crash-diag.log); runs on the calling (game) thread so it knows its id.
    dusk_xbox_crash_diag_start(dir);

    std::wstring path = dir;
    path += L"\\input-diag.log";
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_file = _wfopen(path.c_str(), L"w");
    }
    if (g_file == nullptr) {
        return;
    }
    Out("input diagnostics (SDL %d.%d.%d)", SDL_MAJOR_VERSION, SDL_MINOR_VERSION, SDL_MICRO_VERSION);

    // Redirect SDL's own logging into this file and make the input category chatty. Done before Aurora
    // calls SDL_Init so driver start-up messages are captured too.
    SDL_SetLogOutputFunction(SdlLogSink, nullptr);
    SDL_SetLogPriorities(SDL_LOG_PRIORITY_INFO);
    SDL_SetLogPriority(SDL_LOG_CATEGORY_INPUT, SDL_LOG_PRIORITY_VERBOSE);
    SDL_SetLogPriority(SDL_LOG_CATEGORY_SYSTEM, SDL_LOG_PRIORITY_VERBOSE);

    const char* hints[] = {"SDL_JOYSTICK_WGI", "SDL_JOYSTICK_HIDAPI", "SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS",
                           "SDL_JOYSTICK_DEVICE", "SDL_GAMECONTROLLERCONFIG", "SDL_JOYSTICK_RAWINPUT"};
    for (const char* h : hints) {
        const char* v = SDL_GetHint(h);
        Out("hint %s = %s", h, v != nullptr ? v : "(unset)");
    }

    try {
        std::thread(Worker).detach();
    } catch (...) {
        Out("failed to start diag thread");
    }
}
