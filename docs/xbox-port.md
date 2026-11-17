# Xbox port (experimental)

Target: **Xbox One S** first, then Xbox One X and Xbox Series X|S, running in **Developer Mode** as a
**UWP x64** app (one binary for all three families).

## Status

The app builds in CI, installs as an `.msix`, starts, renders its UI and reads the disc. Whether the
game itself runs past the first scenes is **not verified yet**.

| Piece | State |
| --- | --- |
| Build (VS, WindowsStore x64, SDL3-uwp, Dawn, nod) + signed `.msix` | Works in CI |
| Graphics: Dawn D3D12 on the console (CoreWindow surface) | Verified on hardware (device created, UI renders) |
| Controller (SDL WGI joystick driver, `SDL_JOYSTICK_WGI=1`) | Verified on hardware |
| Disc picker + reading a 1 GB nkit image **in place** from USB | Verified on hardware (disc verifies as "hash mismatch", expected for nkit; "Continue anyway" proceeds) |
| Audio init freeze (SDL WASAPI management-thread deadlock) | Fix in CI build, **untested** on hardware |
| Dawn `disable_resource_suballocation` (CreatePlacedResource crash) | In CI build, **untested** on hardware |
| Sustained gameplay, audio output, saves, performance on One S | Unknown |
| Code mods, Discord, WebSockets | Disabled on Xbox |
| One X / Series specific tuning | Not started |

## How it is built

`platforms/xbox/ci.ps1` (run by `.github/workflows/xbox.yml`, copy of `platforms/xbox/xbox.yml.workflow`):

1. `Cache-Mtimes.ps1 Restore` (incremental MSBuild after actions/cache).
2. `Apply-Patches.ps1 -Phase Source`: small idempotent text patches to `extern/aurora`, `extern/borealis`
   and the game (UWP guards, CoreWindow surface, file picker, probe hook). Fails when an anchor stops
   matching.
3. `Apply-Patches-Disc.ps1`: disc hooks in aurora `dvd.cpp` and borealis `io.cpp`; it also runs
   `Apply-Patches-Sdl.ps1` (SDL3-uwp clone) and `Apply-Patches-Gpu.ps1` (Dawn toggle).
4. Configure (toolchain `cmake/toolchains/xbox-uwp-x64.cmake`, SDL3-uwp via `FETCHCONTENT_SOURCE_DIR_SDL`).
5. `Apply-Patches.ps1 -Phase Deps`: Dawn sources fetched at configure time.
6. `Patch-Manifest.ps1`, build, `Make-Symbols.ps1` + a repackaging build (symbols inside the `.msix`),
   `Cache-Mtimes.ps1 Save`, assets.

The toolchain defines `DUSK_XBOX_UWP=1`. Every tracked file a patch script touches (now or in the past)
must be listed in `$alwaysFresh` of `Cache-Mtimes.ps1`.

## Findings from hardware

- **Graphics backend.** Dawn's D3D11 backend fails on the console (D3D11 feature level 10.1 only, Dawn
  asks for 11.x). D3D12 works. `xbox_gfx_probe*.cpp` checks the backends before Aurora starts.
- **Xbox D3D12 driver faults** (all handled by patches): optional `CheckFeatureSupport` queries (wrapped in
  SEH), `ID3D12PipelineState::GetCachedBlob` (never called; pipelines compile normally, no blob cache),
  and `CreatePlacedResource` (Dawn toggle `disable_resource_suballocation`, untested).
- **Disc access.** The FileOpenPicker returns `E:\...` but opening that path is `ACCESS_DENIED`. The app
  only has the `StorageFile`; `xbox_file_picker.cpp` converts it to a `HANDLE` with
  `IStorageItemHandleAccess` and wraps it in an `SDL_IOStream` (per-thread read positions, because the
  nod preloader and Aurora's DVD worker read the same stream). The choice persists in the
  FutureAccessList (token `disc`) and the game starts automatically on the next launch.
- **Audio freeze.** The SDL3-uwp std::thread backend never sets `SDL_Thread::threadid`, so
  `WASAPI_ProxyToManagementThread` cannot tell it already runs on the management thread and waits on
  itself in `SDL_OpenAudioDevice` (game thread == UI/render thread, so the whole app freezes on a black
  screen right after the logo scene). `Apply-Patches-Sdl.ps1` sets the id in `RunThread`. The fork
  999sian/dusklight found the same bug and fixed it the same way (verified on their console).
- **Data folder buttons** (Open/Change data folder) crashed the app; they are reported unsupported on UWP.
- **Memory.** `Windows.System.MemoryManager` reports a 5120 MiB limit; the app used about 800 MiB at the
  time of the freeze, so memory is not the problem there.

## Diagnostics (in `LocalState\TwilitRealm\Dusklight\`)

| File | Content |
| --- | --- |
| `dusklight-*.log.txt` | Main game log (flushed after every line on Xbox) |
| `gfx-probe.log` | Graphics probe results |
| `input-diag.log` | Controller/SDL input diagnostics |
| `picker.log` | File picker and disc stream (first reads, errors, slow reads) |
| `crash-diag.log`, `crash-diag.prev.log` | First-chance exception reports, abort/terminate hooks, watchdog: disc stats, memory, and stacks of all threads (symbolized from `symbols/dusklight.sym`) at fixed times after the game opens the disc; the previous run is kept as `.prev` |

## Open items

1. Hardware test of the build containing the SDL thread-id fix and the Dawn toggle.
2. Shader model 5.1 (FXC) vs DXC on the console.
3. Performance and memory on the One S (the fork 999sian/dusklight lists CPU work-reduction changes and
   a bundled pipeline seed that we have not adopted).
4. Remove the Cache-Mtimes bootstrap commit once the cache is warm.
5. Series X|S fallback and per-console quality settings.
6. Turn off flush-every-line logging after the diagnosis phase.
