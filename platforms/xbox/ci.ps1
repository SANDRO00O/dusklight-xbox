<#
.SYNOPSIS
  Configure and build the experimental Xbox (UWP, x64) target, writing logs next to the repo root.
  Called by the Xbox (experimental) workflow so the logic can change without editing the workflow.
#>
$ErrorActionPreference = 'Continue'

$buildDir = 'build/xbox-uwp-x64'
$toolchain = 'cmake/toolchains/xbox-uwp-x64.cmake'
$config = 'RelWithDebInfo'

function Write-Section([string]$Title) {
    Write-Host "::group::$Title"
}
function End-Section {
    Write-Host '::endgroup::'
}

# --- Diagnostics: what does this runner actually have? ---
Write-Section 'Tool versions'
cmake --version
rustc --version 2>&1
cargo --version 2>&1
End-Section

Write-Section 'Visual Studio installs and components'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vswhere) {
    & $vswhere -all -products * -format json 2>&1 | Tee-Object -FilePath vswhere.log
    Write-Host '--- UWP-related components ---'
    & $vswhere -all -products * -requires Microsoft.VisualStudio.ComponentGroup.UWP.VC 2>&1
    & $vswhere -all -products * -requires Microsoft.VisualStudio.Component.Windows10SDK.19041 2>&1
} else {
    Write-Host 'vswhere.exe not found'
}
End-Section

# --- Configure ---
# No -G: CMake picks the newest installed Visual Studio generator (required for WindowsStore).
# The -D argument is quoted so PowerShell does not split it at the dot in 'xbox-uwp-x64.cmake'.
Write-Section 'Configure'
cmake -S . -B $buildDir -A x64 "-DCMAKE_TOOLCHAIN_FILE=$toolchain" 2>&1 | Tee-Object -FilePath configure.log
$configureExit = $LASTEXITCODE
End-Section
if ($configureExit -ne 0) {
    Write-Host "Configure failed with exit code $configureExit"
    exit $configureExit
}

# --- Build ---
Write-Section 'Build'
cmake --build $buildDir --config $config --target dusklight 2>&1 | Tee-Object -FilePath build.log
$buildExit = $LASTEXITCODE
End-Section
if ($buildExit -ne 0) {
    Write-Host "Build failed with exit code $buildExit"
    exit $buildExit
}

# --- AppX assets (only after a successful build) ---
./platforms/xbox/Generate-Assets.ps1 -InputPng res/icon.png -OutputDir "$buildDir/Assets"
exit 0
