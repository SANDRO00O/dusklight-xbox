# Xbox port (experimental)

Target: **Xbox One S** first, then Xbox One X and Xbox Series X|S, running in **Developer Mode**.

Retail consoles in Dev Mode run **UWP** apps (x64). All three console families are x64, so a single
binary can serve them, with quality settings scaled per console.

## Status

Scaffolding only. Nothing here has been built or run on hardware yet.

| Piece | State |
| --- | --- |
| `cmake/toolchains/xbox-uwp-x64.cmake` | Written, untested |
| `cmake/WindowsTargetProcessor.cmake` | Handles `WindowsStore` |
| `platforms/xbox/Package.appxmanifest.in` | Template, not yet wired into CMake |
| `platforms/xbox/Generate-Assets.ps1` | Written, untested |
| UWP entry point | Not started |
| Window / input / audio on UWP | Blocked (see below) |
| Disc image selection | Not started |

## Building the scaffold

CMake supports `CMAKE_SYSTEM_NAME=WindowsStore` only with Visual Studio generators:

```sh
cmake -S . -B build/xbox-uwp-x64 -G "Visual Studio 17 2022" -A x64 -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/xbox-uwp-x64.cmake
cmake --build build/xbox-uwp-x64 --config RelWithDebInfo --target dusklight
```

## Blockers

1. **SDL3 has no UWP/WinRT backend.** SDL3 dropped WinRT support. Aurora and Borealis use SDL3 for the
   window, gamepad input, audio, storage paths and the file picker. Options:
   - Add a minimal CoreWindow video + gamepad backend to a fork of SDL3.
   - Add a platform layer to a fork of Aurora/Borealis that replaces SDL on Xbox (CoreWindow,
     `Windows.Gaming.Input` or XInput, XAudio2/WASAPI, `Windows.Storage`).
   - Move to the GDK instead (needs ID@Xbox access or a dev kit, so not available in plain Dev Mode).
2. **Dawn on UWP.** Aurora's renderer uses Dawn (WebGPU) with D3D12. The `package` provider has no
   prebuilt for `WindowsStore`, so the toolchain forces a source build. Whether this configuration
   builds and presents through a CoreWindow still has to be verified.
3. **Disc image loading.** The game is started with `--dvd <path>`. UWP has no command line, so the
   Xbox build needs a file picker (or a fixed folder) feeding `borealis::disc`.
4. **Code mods are disabled** on Xbox (`DUSK_ENABLE_CODE_MODS=OFF`) because funchook patches code at
   runtime. The non-mod path with this option off is not exercised by upstream CI.
5. **Win32-only calls** in `CMakeLists.txt` and `src/dusk/main.cpp` (`Psapi`, console setup,
   `CreateProcessW` restart, `wWinMain`) need guards for UWP.
6. **Memory and performance** on Xbox One S are the tightest of the three consoles.

## Plan

1. Build the scaffold and fix configure/build errors that are independent of the platform layer.
2. Decide and implement the SDL3 replacement (blocker 1).
3. Add the UWP entry point, manifest wiring (`VS_DEPLOYMENT_CONTENT`) and AppX packaging.
4. Disc selection via the file picker.
5. Test on an Xbox One S in Dev Mode, then enable higher quality settings for One X and Series.
