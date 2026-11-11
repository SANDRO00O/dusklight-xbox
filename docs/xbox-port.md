# Xbox port (experimental)

Target: **Xbox One S** first, then Xbox One X and Xbox Series X|S, running in **Developer Mode**.

Retail consoles in Dev Mode run **UWP** apps (x64). All three console families are x64, so a single
binary can serve them, with quality settings scaled per console.

## Status

Scaffolding only. Nothing here has run on hardware yet. CMake configures successfully for
`WindowsStore`, and with the UWP SDL3 fork the dependency tree (SDL3, Dawn, nod, libpng, abseil, ...)
now compiles. The remaining compile errors are in the platform layers of Aurora, Borealis and the
game (see CI findings).

| Piece | State |
| --- | --- |
| `cmake/toolchains/xbox-uwp-x64.cmake` | Configures; dependencies build |
| `cmake/WindowsTargetProcessor.cmake` | Handles `WindowsStore` |
| `platforms/xbox/Package.appxmanifest.in` | Template, not yet wired into CMake |
| `platforms/xbox/Generate-Assets.ps1` | Written, untested |
| `platforms/xbox/ci.ps1` + `xbox.yml.workflow` | Manual CI run: clones SDL3-uwp, patches submodules, builds, uploads logs |
| `platforms/xbox/xbox-project.cmake` | Forces SDL3 to C++17 (`/ZW` vs `/std:c++20`) |
| `platforms/xbox/Apply-Patches.ps1` | Patches Win32-only code in aurora/borealis submodules |
| UWP entry point | Not started |
| Window / input / audio on UWP | Provided by SDL3-uwp, untested here |
| Dawn CoreWindow surface (Aurora patch) | Not started |
| Disc image selection | Not started |

## Building the scaffold

CMake supports `CMAKE_SYSTEM_NAME=WindowsStore` only with Visual Studio generators. Do not pass `-G`
(CMake picks the newest installed Visual Studio; the hosted runner currently has Visual Studio 2026),
and quote the `-D` arguments in PowerShell:

```powershell
git clone --depth 1 --branch uwp-3.4.20 https://github.com/XboxEmulationHub/SDL3-uwp.git build/ext/SDL3-uwp
./platforms/xbox/Apply-Patches.ps1
cmake -S . -B build/xbox-uwp-x64 -A x64 "-DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/xbox-uwp-x64.cmake" "-DFETCHCONTENT_SOURCE_DIR_SDL=$PWD/build/ext/SDL3-uwp"
cmake --build build/xbox-uwp-x64 --config RelWithDebInfo --target dusklight
```

`platforms/xbox/ci.ps1` does exactly this and pins the fork to a commit.

## SDL3 on UWP

Upstream SDL3 has `#error Windows RT/UWP is no longer supported` in `SDL_platform_defines.h`.
[XboxEmulationHub/SDL3-uwp](https://github.com/XboxEmulationHub/SDL3-uwp) is a community fork of
SDL 3.4.20 (the version Aurora pins) with the WinRT backend restored: CoreWindow video, WASAPI audio,
XInput gamepads (Xbox-compatible controllers only), file I/O, paths, threads, timers, a minimal file
picker, and D3D11/D3D12 WinRT render glue. Its top-level `CMakeLists.txt` has `WINDOWS_STORE`
branches that enable C++ and compile the WinRT sources with `/ZW`.

Aurora declares its SDL dependency as `FetchContent_Declare(SDL ...)`, so
`-DFETCHCONTENT_SOURCE_DIR_SDL=<clone>` substitutes the fork without editing Aurora. Side effect: the
Android-only patch commands in Aurora's declaration are skipped, which is irrelevant here.

Notes from the fork's `README-winrt.md`:
- `SDL_main.h` must be included from a C++ file compiled with `/ZW`.
- A `.winmd` needs at least one C++/CX file in the project.
- Link workaround: `/nodefaultlib:vccorlib /nodefaultlib:msvcrt vccorlib.lib msvcrt.lib`.
- The CoreWindow is exposed as `SDL_PROP_WINDOW_WINRT_WINDOW_POINTER`.

Reference UWP port using the same stack: [XBSX2](https://github.com/XboxEmulationHub/XBSX2)
(`pcsx2-uwp/`: `Package.appxmanifest`, `PropertySheet.props`, vcxproj, `src/main.cpp`).

## Patching the submodules

`extern/aurora` and `extern/borealis` point at upstream (`encounter/aurora`, `encounter/borealis`).
Instead of forking both, `platforms/xbox/Apply-Patches.ps1` applies small, idempotent text patches
before configuring. It fails loudly if an anchor stops matching (upstream changed). The toolchain
defines `DUSK_XBOX_UWP=1` for all C/C++ so patched code can branch on it. Current patches:

| File | Problem | Patch |
| --- | --- | --- |
| `aurora/lib/system_info.cpp` | WMI (`IWbemLocator`, `CoSetProxyBlanket`) not in UWP | `#if _WIN32` becomes `#if _WIN32 && !defined(DUSK_XBOX_UWP)` (generic branch logs "Unknown") |
| `borealis/src/io.cpp` | `CreateFileW` not in UWP | `CreateFileW` shim over `CreateFile2` after `<Windows.h>` |

When the set of patches grows, move them into forks of the two submodules.

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
5. **Upstream SDL3: `SDL_platform_defines.h(376): error C1189: #error: Windows RT/UWP is no longer
   supported in SDL`.** Fixed by switching to the SDL3-uwp fork.
6. The UWP project defaults enable `/sdl`, which promotes C4146/C4703/C4996 to errors in Dawn
   (`Device.cpp`, `BufferD3D11.cpp`) and libpng (`pngread.c`, `pngwrite.c`). Fixed with `/sdl-`
   (confirmed: those libraries now compile with warnings only).
7. sqlite3 (Aurora) needs `-DSQLITE_OS_WINRT=1` (compiles now).
8. The Rust crate `nod` builds for `x86_64-pc-windows-msvc` and compiled in CI. Whether it links into
   a UWP binary is still unknown (needs `userenv`, `dbghelp`, `ntdll`).

Run 4 (SDL3-uwp in use):
9. SDL3-uwp configured (`SDL-3.4.20-release-uwp-3.4.20`). `SDL3-static` failed with
   `D8016: '/ZW' and '/std:c++20' are incompatible` because the root `CMakeLists.txt` sets
   `CMAKE_CXX_STANDARD 20`. Fixed by `xbox-project.cmake` (SDL targets get C++17).

Run 5 (SDL3-static C++17 compiled; Dawn, nod, libpng, abseil, freeverb build):
10. `aurora/lib/system_info.cpp`: WMI types undeclared. Patched (above).
11. `borealis/src/io.cpp`: `CreateFileW` not found (2 uses). Patched (above).
12. Not yet reached: `aurora_core`, `borealis_io` dependents, and the `dusklight` target itself.

## Blockers

1. ~~SDL3 has no UWP backend.~~ Solved with SDL3-uwp for the build. Remaining risks: whether every SDL
   API Aurora and Borealis use works on the WinRT backend (gamepad rumble and sensors, power,
   `SDL_Renderer` for ImGui), and the `/ZW`/`vccorlib` link requirements.
2. **Dawn on UWP.** Dawn supports UWP via D3D12/D3D11 and a CoreWindow surface, but Aurora's surface
   code (`extern/aurora/lib/dawn/BackendBinding.cpp`) only has Win32 (`SurfaceSourceWindowsHWND`)
   branches. Needs a UWP branch creating `wgpu::SurfaceSourceWindowsCoreWindow` from
   `SDL_PROP_WINDOW_WINRT_WINDOW_POINTER`.
3. **Disc image loading.** The game is started with `--dvd <path>`. UWP has no command line, so the
   Xbox build needs a file picker (the fork has a minimal picker) or a fixed folder feeding
   `borealis::disc`. UWP file access is brokered, so plain paths outside the app's folders will fail.
4. **Code mods are disabled** on Xbox (`DUSK_ENABLE_CODE_MODS=OFF`) because funchook patches code at
   runtime. The non-mod path with this option off is not exercised by upstream CI.
5. **Win32-only calls** in `CMakeLists.txt` and `src/dusk/main.cpp` (`Psapi`, console setup,
   `CreateProcessW` restart, `wWinMain`) need guards for UWP.
6. **Rust crate `nod`** compiles; linking under UWP is untested.
7. **Memory and graphics API limits on Xbox One S.** Microsoft's archived UWP-on-Xbox docs list
   1 GB for apps and 5 GB for games, and D3D12 only for games on Xbox One (apps are D3D11 FL10.1).
   It is unknown which limits a Dev Mode UWP app gets on a One S. Must be measured on hardware; the
   D3D11 backend may be required.

## Plan

1. Run the CI script, fix the next compile errors (aurora_core, borealis, dusklight).
2. Guard Win32-only code in `src/dusk/main.cpp` and `CMakeLists.txt` (blocker 5).
3. Add the CoreWindow surface branch to Aurora (blocker 2).
4. Link: `nod`, `vccorlib`, `/ZW` entry point.
5. Add the UWP entry point, manifest wiring (`VS_DEPLOYMENT_CONTENT`) and AppX packaging.
6. Disc selection via the file picker (blocker 3).
7. Test on an Xbox One S in Dev Mode (blocker 7), then enable higher quality settings for One X and
   Series.
