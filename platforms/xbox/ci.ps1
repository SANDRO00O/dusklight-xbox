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

# --- Configure ---
# No -G: CMake picks the newest installed Visual Studio generator (required for WindowsStore).
# The -D argument is quoted so PowerShell does not split it at the dot in 'xbox-uwp-x64.cmake'.
Write-Host "Configuring: cmake -S . -B $buildDir -A x64 -DCMAKE_TOOLCHAIN_FILE=$toolchain"
cmake -S . -B $buildDir -A x64 "-DCMAKE_TOOLCHAIN_FILE=$toolchain" 2>&1 | Tee-Object -FilePath configure.log | Out-Null
$configureExit = $LASTEXITCODE
if ($configureExit -ne 0) {
    Show-Failure 'CONFIGURE' 'configure.log' $configureExit
    exit $configureExit
}
Write-Host 'Configure succeeded'

# --- Build ---
cmake --build $buildDir --config $config --target dusklight 2>&1 | Tee-Object -FilePath build.log | Out-Null
$buildExit = $LASTEXITCODE
if ($buildExit -ne 0) {
    Show-Failure 'BUILD' 'build.log' $buildExit
    exit $buildExit
}
Write-Host 'Build succeeded'

# --- AppX assets (only after a successful build) ---
./platforms/xbox/Generate-Assets.ps1 -InputPng res/icon.png -OutputDir "$buildDir/Assets"
exit 0
