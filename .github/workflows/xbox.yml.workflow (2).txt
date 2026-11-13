name: Xbox (experimental)

# Manual only. All build logic lives in platforms/xbox/ci.ps1 so it can change without touching
# this file. See docs/xbox-port.md.
# Copy this file to .github/workflows/xbox.yml to enable it.
#
# Build cache: build/xbox-uwp-x64 (MSBuild objects, Rust target dir), build/ext (SDL3-uwp clone) and
# the cargo registry are restored from actions/cache and saved after every run, even a failed one.
# platforms/xbox/Cache-Mtimes.ps1 fixes file mtimes so MSBuild only rebuilds what changed.
# The first run after adding this is a normal cold build. Use the no_cache input for a clean build
# (it also replaces the saved cache), or bump CACHE_VERSION to drop every old cache.
on:
  workflow_dispatch:
    inputs:
      no_cache:
        description: 'Ignore the saved build cache (clean build; the result is saved as the new cache)'
        type: boolean
        default: false

env:
  CACHE_VERSION: v1

jobs:
  build-xbox-uwp:
    name: Xbox UWP x64 (configure + build)
    runs-on: windows-latest

    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
          submodules: recursive

      - name: Install Rust targets
        shell: pwsh
        run: |
          rustup toolchain install stable
          rustup target add x86_64-pc-windows-msvc

      # The runner image version changes the Visual Studio / MSVC / SDK versions, so it is part of
      # the cache key: a new image starts from a clean cache instead of mixing toolchains.
      - name: Compute cache key
        id: cachekey
        shell: pwsh
        run: |
          $image = if ($env:ImageVersion) { $env:ImageVersion } else { 'unknown' }
          "prefix=xbox-uwp-$($env:CACHE_VERSION)-$image-" >> $env:GITHUB_OUTPUT

      - name: Restore build cache
        if: ${{ !inputs.no_cache }}
        uses: actions/cache/restore@v4
        with:
          path: |
            build/xbox-uwp-x64
            build/ext
            ~/.cargo/registry
            ~/.cargo/git
          key: ${{ steps.cachekey.outputs.prefix }}${{ github.run_id }}
          restore-keys: |
            ${{ steps.cachekey.outputs.prefix }}

      - name: Configure and build
        shell: pwsh
        run: ./platforms/xbox/ci.ps1

      - name: Save build cache
        if: ${{ !cancelled() }}
        uses: actions/cache/save@v4
        with:
          path: |
            build/xbox-uwp-x64
            build/ext
            ~/.cargo/registry
            ~/.cargo/git
          key: ${{ steps.cachekey.outputs.prefix }}${{ github.run_id }}

      - name: Upload logs
        if: always()
        uses: actions/upload-artifact@v7
        with:
          name: xbox-uwp-logs
          path: |
            configure.log
            build.log
            patches.log
            cache-restore.log
            sdl-clone.log
            vswhere.log
            build/xbox-uwp-x64/CMakeFiles/CMakeConfigureLog.yaml
            build/xbox-uwp-x64/Assets/
          if-no-files-found: ignore
