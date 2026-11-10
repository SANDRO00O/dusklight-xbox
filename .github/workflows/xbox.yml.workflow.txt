name: Xbox (experimental)

# Manual only. The Xbox (UWP, Dev Mode) port is not buildable yet; run this to get configure/build
# logs that show the next blocker. See docs/xbox-port.md.
# Move this file to .github/workflows/xbox.yml to enable it.
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

      - name: Install Rust x64 target
        shell: pwsh
        run: |
          rustup toolchain install stable
          rustup target add x86_64-pc-windows-msvc

      - name: Configure CMake
        shell: pwsh
        run: |
          cmake -S . -B build/xbox-uwp-x64 -G "Visual Studio 17 2022" -A x64 `
            -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/xbox-uwp-x64.cmake 2>&1 | Tee-Object -FilePath configure.log
          exit $LASTEXITCODE

      - name: Build
        shell: pwsh
        run: |
          cmake --build build/xbox-uwp-x64 --config RelWithDebInfo --target dusklight 2>&1 | Tee-Object -FilePath build.log
          exit $LASTEXITCODE

      - name: Generate AppX assets
        if: success()
        shell: pwsh
        run: |
          ./platforms/xbox/Generate-Assets.ps1 -InputPng res/icon.png -OutputDir build/xbox-uwp-x64/Assets

      - name: Upload logs
        if: always()
        uses: actions/upload-artifact@v7
        with:
          name: xbox-uwp-logs
          path: |
            configure.log
            build.log
            build/xbox-uwp-x64/CMakeFiles/CMakeConfigureLog.yaml
            build/xbox-uwp-x64/Assets/
          if-no-files-found: ignore
