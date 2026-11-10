# Xbox port (experimental)

Target: **Xbox One S** first, then Xbox One X and Xbox Series X|S, running in **Developer Mode**.

Retail consoles in Dev Mode run **UWP** apps (x64). All three console families are x64, so a single
binary can serve them, with quality settings scaled per console.

## Status

Scaffolding only. Nothing here has run on hardware yet. CMake configures successfully for
`WindowsStore`; the build fails in SDL3 (see Blocker 1), which cannot be worked around.

| Piece | State |
| --- | --- |
| `cmake/toolchains/xbox-uwp-x64.cmake` | Configures; build blocked by SDL3 |
| `cmake/WindowsTargetProcessor.cmake` | Handles `WindowsStore` |
| `platforms/xbox/Package.appxmanifest.in` | Template, not yet wired into CMake |
| `platforms/xbox/Generate-Assets.ps1` | Written, untested |
| `platforms/xbox/ci.ps1` + `xbox.yml.workflow` | Manual CI run, uploads logs |
| UWP entry point | Not started |
| Window / input / audio on UWP | Blocked (see below) |
| Disc image selection | Not started |

## Building the scaffold

CMake supports `CMAKE_SYSTEM_NAME=WindowsStore` only with Visual Studio generators. Do not pass `-G`
(CMake picks the newest installed Visual Studio; the hosted runner currently has Visual Studio 2026),
and quote the `-D` argument in PowerShell:

```powershell
cmake -S . -B build/xbox-uwp-x64 -A x64 "-DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/xbox-uwp-x64.cmake"
cmake --build build/xbox-uwp-x64 --config RelWithDebInfo --target dusklight
```

## CI findings

Run 1 (configure):
1. PowerShell split an unquoted `-DCMAKE_TOOLCHAIN_FILE=...xbox-uwp-x64.cmake` at the dot. Quote it.
2. The hosted `windows-latest` runner has Visual Studio 2026 (generator `Visual Studio 18 2026`), so
   a hard-coded `Visual Studio 17 2022` fails. Omit `-G`.

Run 2 (configure):
3. Dawn's CMake handles `WINDOWS_STORE` (D3D11/D3D12 backends only, Vulkan and GLFW off, Windows
   UI/CoreWindow surface on).
4. Dawn's protobuf needs a host `protoc` when cross-compiling. Fixed with `DAWN_BUILD_PROTOBUF=OFF`
   and `TINT_BUILD_IR_BINARY=OFF`.

Run 3 (configure OK in ~280 s, then build):
5. **SDL3: `SDL_platform_defines.h(376): error C1189: #error: Windows RT/UWP is no longer supported
   in SDL`.** Hard stop, not a flag problem.
6. The UWP project defaults enable `/sdl`, which promotes C4146/C4703/C4996 to errors in Dawn
   (`Device.cpp`, `BufferD3D11.cpp`) and libpng (`pngread.c`, `pngwrite.c`). Fixed with `/sdl-`.
7. sqlite3 (Aurora) fails with undeclared `CreateFileA/W`, `GetFileSize`, `HeapValidate`,
   `AreFileApisANSI`: desktop-only APIs. Fixed with `-DSQLITE_OS_WINRT=1`.
8. The Rust crate `nod` built for `x86_64-pc-windows-msvc` (the desktop target), and its required
   libraries (`userenv`, `dbghelp`, `ntdll`) are not available to UWP apps. Expected to fail at link.

## Blockers

1. **SDL3 has no UWP/WinRT backend** (confirmed by CI: `#error` in the public header). Aurora uses
   SDL3 in about 50 files (events, gamepad and sensors, window, threads, IO streams, filesystem,
   timer, power, mouse, `SDL_Renderer` for ImGui) and Borealis in about 20 (IO streams, filesystem,
   file select, data paths, timer). Options:
   - Add a minimal CoreWindow video + gamepad backend to a fork of SDL3 (the WinRT code was removed
     from SDL3, so it would be rewritten, possibly adapted from SDL2's WinRT backend).
   - Write an SDL3-compatible shim covering only the API subset above, backed by CoreWindow,
     `Windows.Gaming.Input` or XInput, XAudio2/WASAPI and `Windows.Storage`.
   - Move to the GDK instead (needs ID@Xbox access or a dev kit, so not available in plain Dev Mode).
2. **Dawn on UWP.** Dawn supports UWP via D3D12 and a CoreWindow surface, but Aurora's code that
   creates the surface goes through SDL. The Xbox platform layer must hand Dawn a CoreWindow.
3. **Disc image loading.** The game is started with `--dvd <path>`. UWP has no command line, so the
   Xbox build needs a file picker (or a fixed folder) feeding `borealis::disc`.
4. **Code mods are disabled** on Xbox (`DUSK_ENABLE_CODE_MODS=OFF`) because funchook patches code at
   runtime. The non-mod path with this option off is not exercised by upstream CI.
5. **Win32-only calls** in `CMakeLists.txt` and `src/dusk/main.cpp` (`Psapi`, console setup,
   `CreateProcessW` restart, `wWinMain`) need guards for UWP.
6. **Rust crate `nod`** has to build for a UWP-compatible target and link without desktop-only libs.
7. **Memory and performance** on Xbox One S are the tightest of the three consoles.

## Plan

1. Run the CI script, fix configure and build errors that are independent of the platform layer.
2. Decide and implement the SDL3 replacement (blocker 1).
3. Add the UWP entry point, manifest wiring (`VS_DEPLOYMENT_CONTENT`) and AppX packaging.
4. Disc selection via the file picker.
5. Test on an Xbox One S in Dev Mode, then enable higher quality settings for One X and Series.
