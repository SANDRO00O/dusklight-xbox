<#
.SYNOPSIS
  Configure and build the experimental Xbox (UWP, x64) target, writing logs next to the repo root.
  Called by the Xbox (experimental) workflow so the logic can change without editing the workflow.
  On failure the relevant errors are printed OUTSIDE any collapsed group so they can be copied
  straight from the run page.
#>
$ErrorActionPreference = 'Continue'

$buildDir = 'build/xbox-uwp-x64'
$toolchain = 'cmake/toolchains/xbox-uwp-x64.cmake'
$config = 'RelWithDebInfo'

# UWP-capable SDL3 (community fork of libsdl-org/SDL 3.4.20 with the WinRT backend restored).
# Upstream SDL3 stops with '#error Windows RT/UWP is no longer supported'. Pinned to a commit so CI
# is reproducible; branch uwp-3.4.20 matches the SDL version pinned by Aurora.
$sdlUwpRepo = 'https://github.com/XboxEmulationHub/SDL3-uwp.git'
$sdlUwpBranch = 'uwp-3.4.20'
$sdlUwpCommit = 'ec2e0e7c77ec9a04437eb3ae884d62ae0e6129b4'
$sdlUwpDir = Join-Path (Get-Location) 'build/ext/SDL3-uwp'

function Show-Failure([string]$Stage, [string]$LogFile, [int]$ExitCode) {
    Write-Host ''
    Write-Host "################ $Stage FAILED (exit code $ExitCode) ################"
    if (Test-Path $LogFile) {
        $lines = Get-Content $LogFile
        Write-Host "---- error lines from $LogFile ----"
        $lines | Select-String -Pattern 'CMake Error', 'error C\d+', 'error:', 'fatal error', 'LNK\d+', 'Could not find', 'could not find', 'not found', 'FAILED' -Context 0, 3 | Select-Object -First 80 | ForEach-Object { $_.ToString() }
        Write-Host "---- last 60 lines of $LogFile ----"
        $lines | Select-Object -Last 60
    } else {
        Write-Host "$LogFile was not created"
    }
    Write-Host '################ end of failure details ################'
}

# --- Diagnostics: what does this runner actually have? ---
Write-Host '::group::Tool versions'
cmake --version
rustc --version 2>&1
cargo --version 2>&1
git --version
Write-Host '::endgroup::'

# Short, always-visible summary of Visual Studio (full JSON goes to vswhere.log).
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vswhere) {
    & $vswhere -all -products * -format json 2>&1 | Out-File -FilePath vswhere.log -Encoding utf8
    Write-Host '--- Visual Studio installs ---'
    & $vswhere -all -products * -property displayName, installationVersion, installationPath 2>&1
    $uwp = & $vswhere -all -products * -requires Microsoft.VisualStudio.ComponentGroup.UWP.VC 2>&1
    Write-Host ('UWP C++ component group present: ' + [bool]$uwp)
    $uwpSdk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Include" -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    Write-Host ('Windows 10/11 SDK versions: ' + ($uwpSdk -join ', '))
} else {
    Write-Host 'vswhere.exe not found'
}

# --- Fetch the UWP SDL3 fork ---
if (-not (Test-Path (Join-Path $sdlUwpDir 'CMakeLists.txt'))) {
    Write-Host "Cloning $sdlUwpRepo ($sdlUwpBranch) into $sdlUwpDir"
    New-Item -ItemType Directory -Force -Path (Split-Path $sdlUwpDir) | Out-Null
    git clone --depth 1 --branch $sdlUwpBranch $sdlUwpRepo $sdlUwpDir 2>&1 | Tee-Object -FilePath sdl-clone.log | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Show-Failure 'SDL3-UWP CLONE' 'sdl-clone.log' $LASTEXITCODE
        exit $LASTEXITCODE
    }
}
$sdlHead = (git -C $sdlUwpDir rev-parse HEAD).Trim()
Write-Host "SDL3-uwp HEAD: $sdlHead"
if ($sdlHead -ne $sdlUwpCommit) {
    # Branch moved since this script was written. Not fatal, but visible in the log.
    Write-Host "::warning::SDL3-uwp branch $sdlUwpBranch is at $sdlHead, expected $sdlUwpCommit"
}

# --- Patch third-party submodules (Win32-only code that does not build for UWP) ---
./platforms/xbox/Apply-Patches.ps1 2>&1 | Tee-Object -FilePath patches.log
if ($LASTEXITCODE -ne 0) {
    Write-Host '################ PATCHING FAILED: an anchor in a submodule did not match (see patches.log) ################'
    exit 1
}

# --- Configure ---
# No -G: CMake picks the newest installed Visual Studio generator (required for WindowsStore).
# The -D arguments are quoted so PowerShell does not split them at dots.
# FETCHCONTENT_SOURCE_DIR_SDL makes Aurora's FetchContent_Declare(SDL ...) use the fork instead of
# downloading upstream SDL (this also skips Aurora's Android-only patch commands).
Write-Host "Configuring: cmake -S . -B $buildDir -A x64 -DCMAKE_TOOLCHAIN_FILE=$toolchain -DFETCHCONTENT_SOURCE_DIR_SDL=$sdlUwpDir"
cmake -S . -B $buildDir -A x64 "-DCMAKE_TOOLCHAIN_FILE=$toolchain" "-DFETCHCONTENT_SOURCE_DIR_SDL=$sdlUwpDir" 2>&1 | Tee-Object -FilePath configure.log | Out-Null
$configureExit = $LASTEXITCODE
if ($configureExit -ne 0) {
    Show-Failure 'CONFIGURE' 'configure.log' $configureExit
    exit $configureExit
}
Write-Host 'Configure succeeded'

# --- Build ---
# MSBuild keeps going past a failing project, so one run reports every independent error.
cmake --build $buildDir --config $config --target dusklight 2>&1 | Tee-Object -FilePath build.log | Out-Null
$buildExit = $LASTEXITCODE
if ($buildExit -ne 0) {
    Show-Failure 'BUILD' 'build.log' $buildExit
    exit $buildExit
}
Write-Host 'Build succeeded'

# --- Collect the AppX/MSIX package CMake's WindowsStore support produced ---
# Copied under Assets/_package so the workflow's existing artifact path (build/xbox-uwp-x64/Assets/)
# uploads it without a workflow change.
$assetsDir = Join-Path $buildDir 'Assets'
$pkgSrc = Join-Path $buildDir 'AppPackages'
New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null
if (Test-Path $pkgSrc) {
    Copy-Item -Recurse -Force $pkgSrc (Join-Path $assetsDir '_package')
    Write-Host '--- package files ---'
    Get-ChildItem -Recurse (Join-Path $assetsDir '_package') -File | ForEach-Object { '{0,12:N0}  {1}' -f $_.Length, $_.FullName.Substring((Get-Location).Path.Length + 1) }
} else {
    Write-Host "::warning::$pkgSrc does not exist, no package was produced"
}

# --- AppX assets ---
./platforms/xbox/Generate-Assets.ps1 -InputPng res/icon.png -OutputDir "$buildDir/Assets"
exit 0
