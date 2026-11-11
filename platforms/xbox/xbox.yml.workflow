name: Xbox (experimental)

# Manual only. All build logic lives in platforms/xbox/ci.ps1 so it can change without touching
# this file. See docs/xbox-port.md.
# Copy this file to .github/workflows/xbox.yml to enable it.
on:
  workflow_dispatch:

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

      - name: Configure and build
        shell: pwsh
        run: ./platforms/xbox/ci.ps1

      - name: Upload logs
        if: always()
        uses: actions/upload-artifact@v7
        with:
          name: xbox-uwp-logs
          path: |
            configure.log
            build.log
            patches.log
            sdl-clone.log
            vswhere.log
            build/xbox-uwp-x64/CMakeFiles/CMakeConfigureLog.yaml
            build/xbox-uwp-x64/Assets/
          if-no-files-found: ignore
