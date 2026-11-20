<#
.SYNOPSIS
  Configure and build the experimental Xbox (UWP, x64) target, writing logs next to the repo root.
  Called by the Xbox (experimental) workflow so the logic can change without editing the workflow.
  On failure the relevant errors are printed OUTSIDE any collapsed group so they can be copied
  straight from the run page.
#>
$ErrorActionPreference = 'Continue'

# --- Native (code) mods: automatic fallback -------------------------------------------------------------
# platforms/xbox/code-mods.txt turns the native mods on (default). They add CMake steps and compile code that has
# never been built for UWP before. This script therefore runs itself once as a child process; when that run
# fails in CONFIGURE or BUILD (see ci-stage.txt, written below) while mods were on, the failed logs are kept as
# build/xbox-uwp-x64/Assets/mods-failed-*.log and the whole script runs a second time with
# DUSK_XBOX_FORCE_MODS_OFF=1 (read by the toolchain file) so a package without native mods is still produced.
if (-not $env:DUSK_XBOX_CI_INNER) {
    $env:DUSK_XBOX_CI_INNER = '1'
    $modsWanted = $true
    $modsCfg = 'platforms/xbox/code-mods.txt'
    if ((Test-Path $modsCfg) -and ((Get-Content -Raw $modsCfg) -match '(?m)^\s*mods\s*=\s*off')) { $modsWanted = $false }
    Remove-Item -Force 'ci-stage.txt' -ErrorAction SilentlyContinue
    Get-ChildItem 'build/xbox-uwp-x64/Assets' -Filter 'mods-failed-*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item -Force 'build/xbox-uwp-x64/Assets/NO-NATIVE-MODS.txt' -ErrorAction SilentlyContinue
    $pwshExe = (Get-Process -Id $PID).Path
    & $pwshExe -NoProfile -File $PSCommandPath
    $rc = $LASTEXITCODE
    if ($rc -ne 0 -and $modsWanted) {
        $stage = if (Test-Path 'ci-stage.txt') { (Get-Content -Raw 'ci-stage.txt').Trim() } else { '' }
        if ($stage -eq 'configure' -or $stage -eq 'build') {
            Write-Host ''
            Write-Host "::warning::The build WITH native mods failed in stage '$stage'. Retrying WITHOUT native mods so a package is still produced. The failed logs are in Assets/mods-failed-*.log."
            $keepDir = 'build/xbox-uwp-x64/Assets'
            New-Item -ItemType Directory -Force -Path $keepDir | Out-Null
            foreach ($f in 'configure.log', 'build.log', 'patches.log') {
                if (Test-Path $f) { Copy-Item $f (Join-Path $keepDir ("mods-failed-" + $f)) -Force }
            }
            "stage=$stage exit=$rc" | Out-File -FilePath (Join-Path $keepDir 'mods-failed-info.txt') -Encoding ascii
            $env:DUSK_XBOX_FORCE_MODS_OFF = '1'
            Remove-Item -Force 'ci-stage.txt' -ErrorAction SilentlyContinue
            & $pwshExe -NoProfile -File $PSCommandPath
            $rc = $LASTEXITCODE
            if ($rc -eq 0) {
                'This package was built WITHOUT native mods because the build with mods failed (see mods-failed-*.log).' | Out-File -FilePath (Join-Path $keepDir 'NO-NATIVE-MODS.txt') -Encoding ascii
                Write-Host '::warning::package built WITHOUT native mods (fallback)'
            }
        }
    }
    exit $rc
}

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
    $vsInfo = Get-Content -Raw 'vswhere.log' | ConvertFrom-Json
    $vsInfo | ForEach-Object { Write-Host ("{0} | {1} | {2}" -f $_.displayName, $_.installationVersion, $_.installationPath) }
    $uwp = & $vswhere -all -products * -requires Microsoft.VisualStudio.ComponentGroup.UWP.VC 2>&1
    Write-Host ('UWP C++ component group present: ' + [bool]$uwp)
    $uwpSdk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Include" -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    Write-Host ('Windows 10/11 SDK versions: ' + ($uwpSdk -join ', '))
} else {
    Write-Host 'vswhere.exe not found'
}

# --- Fetch the UWP SDL3 fork ---
# build/ext is part of the CI cache, so on a cache hit the clone (with its original file mtimes) is
# reused and SDL is not rebuilt.
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

# --- Incremental build cache: give unchanged sources an old mtime (no-op on a cold build) ---
# Must run before Apply-Patches.ps1. See Cache-Mtimes.ps1.
./platforms/xbox/Cache-Mtimes.ps1 -Mode Restore 2>&1 | Tee-Object -FilePath cache-restore.log

# --- Patch third-party submodules (Win32-only code that does not build for UWP) ---
./platforms/xbox/Apply-Patches.ps1 -Phase Source 2>&1 | Tee-Object -FilePath patches.log
if ($LASTEXITCODE -ne 0) {
    Write-Host '################ PATCHING FAILED: an anchor in a submodule did not match (see patches.log) ################'
    exit 1
}

# --- Disc access hooks (aurora dvd.cpp, borealis io.cpp): read the picked ISO through its StorageFile ---
./platforms/xbox/Apply-Patches-Disc.ps1 2>&1 | Tee-Object -FilePath patches.log -Append
if ($LASTEXITCODE -ne 0) {
    Write-Host '################ DISC PATCHING FAILED: an anchor in aurora/borealis did not match (see patches.log) ################'
    exit 1
}

# --- CMakeLists.txt: skip the in-tree mods on Xbox (native mods: code-mods.txt, PatchFunchookUwp.cmake) ---
./platforms/xbox/Apply-Patches-Mods.ps1 2>&1 | Tee-Object -FilePath patches.log -Append
if ($LASTEXITCODE -ne 0) {
    Write-Host '################ MODS PATCHING FAILED: an anchor in CMakeLists.txt did not match (see patches.log) ################'
    exit 1
}

# --- Symbol table placeholder + stale linker map ---
# xbox-project.cmake packages <build>/dusklight.sym as symbols/dusklight.sym (function names for the stack
# traces in crash-diag.log). It always starts as a placeholder so a table of an older build can never be
# packaged; the real one is generated from the linker map after the first build (see below). The map is
# removed so the link step runs again and writes a map that matches this build's exe.
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
$symFile = Join-Path $buildDir 'dusklight.sym'
$mapFile = Join-Path $buildDir 'dusklight.map'
'no symbols in this build' | Out-File -FilePath $symFile -Encoding ascii
Remove-Item -Force $mapFile -ErrorAction SilentlyContinue

# --- Configure ---
# No -G: CMake picks the newest installed Visual Studio generator (required for WindowsStore).
# The -D arguments are quoted so PowerShell does not split them at dots.
# FETCHCONTENT_SOURCE_DIR_SDL makes Aurora's FetchContent_Declare(SDL ...) use the fork instead of
# downloading upstream SDL (this also skips Aurora's Android-only patch commands).
'configure' | Out-File -FilePath 'ci-stage.txt' -Encoding ascii
Write-Host "Configuring: cmake -S . -B $buildDir -A x64 -DCMAKE_TOOLCHAIN_FILE=$toolchain -DFETCHCONTENT_SOURCE_DIR_SDL=$sdlUwpDir"
$sw = [Diagnostics.Stopwatch]::StartNew()
cmake -S . -B $buildDir -A x64 "-DCMAKE_TOOLCHAIN_FILE=$toolchain" "-DFETCHCONTENT_SOURCE_DIR_SDL=$sdlUwpDir" 2>&1 | Tee-Object -FilePath configure.log | Out-Null
$configureExit = $LASTEXITCODE
Write-Host ('Configure took {0:N0}s' -f $sw.Elapsed.TotalSeconds)
if ($configureExit -ne 0) {
    Show-Failure 'CONFIGURE' 'configure.log' $configureExit
    exit $configureExit
}
Write-Host 'Configure succeeded'

# --- Patch sources CMake downloaded at configure time (Dawn) ---
./platforms/xbox/Apply-Patches.ps1 -Phase Deps 2>&1 | Tee-Object -FilePath patches.log -Append
if ($LASTEXITCODE -ne 0) {
    Write-Host '################ DEPENDENCY PATCHING FAILED: an anchor in a downloaded source did not match (see patches.log) ################'
    exit 1
}

# --- Patch the AppX manifest CMake generated (capabilities for reading the disc image from USB) ---
# Not fatal if it fails (the build still works, only USB access would be missing), but loud.
$manifestOk = $true
try {
    ./platforms/xbox/Patch-Manifest.ps1 -BuildDir $buildDir 2>&1 | Tee-Object -FilePath manifest.log
} catch {
    $manifestOk = $false
    Write-Host "::warning::Patch-Manifest.ps1 failed: $_"
    "$_" | Out-File -FilePath manifest.log -Append
}

# --- Build ---
# MSBuild keeps going past a failing project, so one run reports every independent error.
$sw.Restart()
'build' | Out-File -FilePath 'ci-stage.txt' -Encoding ascii
cmake --build $buildDir --config $config --target dusklight 2>&1 | Tee-Object -FilePath build.log | Out-Null
$buildExit = $LASTEXITCODE
Write-Host ('Build took {0:N0}s' -f $sw.Elapsed.TotalSeconds)
if ($buildExit -ne 0) {
    Show-Failure 'BUILD' 'build.log' $buildExit
    exit $buildExit
}
Write-Host 'Build succeeded'
'post' | Out-File -FilePath 'ci-stage.txt' -Encoding ascii

# --- Symbol table for crash / hang stack traces, then repackage ---
# Everything in this block is best effort: when it fails the first package (placeholder symbol table) stays.
try {
    if (Test-Path $mapFile) {
        ./platforms/xbox/Make-Symbols.ps1 -MapFile $mapFile -OutFile $symFile 2>&1 | Tee-Object -FilePath symbols.log
        $symSize = (Get-Item $symFile).Length
        Write-Host ('symbol table: {0:N0} bytes' -f $symSize)
        $pkgDir = Join-Path $buildDir 'AppPackages'
        $pkgBak = Join-Path $buildDir 'AppPackages.nosyms'
        if (($symSize -gt 4096) -and (Test-Path $pkgDir)) {
            Remove-Item -Recurse -Force $pkgBak -ErrorAction SilentlyContinue
            Move-Item -Path $pkgDir -Destination $pkgBak
            $sw.Restart()
            cmake --build $buildDir --config $config --target dusklight 2>&1 | Tee-Object -FilePath build-symbols.log | Out-Null
            $repackExit = $LASTEXITCODE
            Write-Host ('Repackaging build took {0:N0}s (exit code {1})' -f $sw.Elapsed.TotalSeconds, $repackExit)
            if (($repackExit -ne 0) -or (-not (Test-Path $pkgDir))) {
                Write-Host '::warning::repackaging with the symbol table failed, keeping the package without symbols'
                Remove-Item -Recurse -Force $pkgDir -ErrorAction SilentlyContinue
                Move-Item -Path $pkgBak -Destination $pkgDir
            } else {
                Remove-Item -Recurse -Force $pkgBak -ErrorAction SilentlyContinue
                # Is the table really inside the package?
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                Get-ChildItem -Path $pkgDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.msix', '.appx' } | ForEach-Object {
                    $zip = [System.IO.Compression.ZipFile]::OpenRead($_.FullName)
                    try {
                        $entry = $zip.Entries | Where-Object { $_.FullName -match 'symbols[/\\]dusklight\.sym$' } | Select-Object -First 1
                        if ($entry) {
                            Write-Host ('{0}: symbols/dusklight.sym = {1:N0} bytes' -f $_.Name, $entry.Length)
                            if ($entry.Length -lt 4096) { Write-Host "::warning::$($_.Name) still has the placeholder symbol table" }
                        } else {
                            Write-Host "::warning::$($_.Name) does not contain symbols/dusklight.sym"
                        }
                    } finally {
                        $zip.Dispose()
                    }
                }
            }
        } else {
            Write-Host '::warning::no usable symbol table or no package, skipping the repackaging build'
        }
        # The map is large; keep it out of the build cache.
        Remove-Item -Force $mapFile -ErrorAction SilentlyContinue
    } else {
        Write-Host "::warning::$mapFile was not produced, the package has no symbol table"
    }
} catch {
    Write-Host "::warning::symbol table step failed: $_"
}

# Record the commits this build corresponds to (only after a successful build, see Cache-Mtimes.ps1).
./platforms/xbox/Cache-Mtimes.ps1 -Mode Save

$assetsDir = Join-Path $buildDir 'Assets'
New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null

# --- Which manifest ended up in the package? (copied into the logs artifact for inspection) ---
$manifestCopies = Join-Path $assetsDir 'manifests'
New-Item -ItemType Directory -Force -Path $manifestCopies | Out-Null
$i = 0
Get-ChildItem -Path $buildDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ieq 'AppxManifest.xml' -or $_.Name -ieq 'Package.appxmanifest' } |
    Where-Object { $_.FullName -notmatch '[\\/](_deps|ext)[\\/]' } |
    ForEach-Object {
        $i++
        Copy-Item $_.FullName (Join-Path $manifestCopies ("{0}-{1}" -f $i, $_.Name)) -Force
        $hasCap = (Get-Content -Raw $_.FullName) -match 'broadFileSystemAccess'
        Write-Host ("manifest: {0} (has broadFileSystemAccess: {1})" -f $_.FullName, $hasCap)
        if (-not $hasCap) { Write-Host "::warning::$($_.FullName) does not contain the patched capabilities" }
    }

# --- Imports of the produced exe (written to Assets/imports.log) ---
# The Rust crate `nod` is built for the desktop target and asks for kernel32;ntdll;userenv;ws2_32;dbghelp.
# Whether those DLLs can be loaded by a UWP app on the console is unknown, so list every imported DLL
# (and the functions of the suspicious ones) to review before testing on hardware.
$exe = Join-Path $buildDir "$config/dusklight.exe"
if ((Test-Path $exe) -and (Test-Path $vswhere)) {
    $dumpbin = & $vswhere -latest -products * -find 'VC\Tools\MSVC\**\bin\Hostx64\x64\dumpbin.exe' 2>$null | Select-Object -First 1
    if ($dumpbin) {
        $importsLog = Join-Path $assetsDir 'imports.log'
        & $dumpbin /nologo /imports $exe 2>&1 | Out-File -FilePath $importsLog -Encoding utf8
        Write-Host '--- imported DLLs of dusklight.exe ---'
        Select-String -Path $importsLog -Pattern '^\s+\S+\.dll\s*$' | ForEach-Object { $_.Line.Trim() } | Sort-Object -Unique | ForEach-Object { '  ' + $_ }
    } else {
        Write-Host '::warning::dumpbin.exe not found, imports.log skipped'
    }
}

# --- Native mods: what ended up in the build and the package? (Assets/mods-build.log) ---
# Best effort. Shows whether native mods were compiled in, the size of the exported symbol list, and whether the
# dusklight.exe inside the .msix is the one the post-link step embedded the symbol manifest into (same size as
# the built exe) and whether the VC runtime DLLs for desktop-built mods are in the package.
try {
    $modsLog = Join-Path $assetsDir 'mods-build.log'
    $lines = @()
    $lines += "FORCE_MODS_OFF=$($env:DUSK_XBOX_FORCE_MODS_OFF)"
    $cache = Join-Path $buildDir 'CMakeCache.txt'
    if (Test-Path $cache) { $lines += (Select-String -Path $cache -Pattern '^(DUSK_ENABLE_CODE_MODS|DUSK_HAS_FUNCHOOK):' | ForEach-Object { $_.Line }) }
    foreach ($def in (Get-ChildItem -Path $buildDir -Recurse -Filter 'dusklight_exports.def' -ErrorAction SilentlyContinue)) {
        $n = (Get-Content $def.FullName | Measure-Object -Line).Lines
        $lines += ("exports def: {0} ({1:N0} lines)" -f $def.FullName, $n)
    }
    foreach ($lib in (Get-ChildItem -Path $buildDir -Recurse -Filter 'dusklight_imports.lib' -ErrorAction SilentlyContinue)) {
        $lines += ("import library: {0} ({1:N0} bytes)" -f $lib.FullName, $lib.Length)
    }
    if (Test-Path $exe) { $lines += ("built exe: {0:N0} bytes" -f (Get-Item $exe).Length) }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Get-ChildItem -Path (Join-Path $buildDir 'AppPackages') -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.msix', '.appx' } | ForEach-Object {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($_.FullName)
        try {
            $e = $zip.Entries | Where-Object { $_.FullName -ieq 'dusklight.exe' } | Select-Object -First 1
            if ($e) { $lines += ("{0}: dusklight.exe in package = {1:N0} bytes" -f $_.Name, $e.Length) }
            foreach ($d in 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll') {
                $has = [bool]($zip.Entries | Where-Object { $_.FullName -ieq $d })
                $lines += ("{0}: {1} in package: {2}" -f $_.Name, $d, $has)
            }
        } finally { $zip.Dispose() }
    }
    $lines | Out-File -FilePath $modsLog -Encoding ascii
    Write-Host '--- native mods build info ---'
    $lines | ForEach-Object { '  ' + $_ }
} catch {
    Write-Host "::warning::mods build info failed: $_"
}

# --- Collect the AppX/MSIX package CMake's WindowsStore support produced ---
# Copied under Assets/_package so the workflow's existing artifact path (build/xbox-uwp-x64/Assets/)
# uploads it without a workflow change. The old copy is removed first: with a restored build cache
# it could still hold the package of an earlier run.
$pkgSrc = Join-Path $buildDir 'AppPackages'
if (Test-Path $pkgSrc) {
    Remove-Item -Recurse -Force (Join-Path $assetsDir '_package') -ErrorAction SilentlyContinue
    Copy-Item -Recurse -Force $pkgSrc (Join-Path $assetsDir '_package')
    Write-Host '--- package files ---'
    Get-ChildItem -Recurse (Join-Path $assetsDir '_package') -File | ForEach-Object { '{0,12:N0}  {1}' -f $_.Length, $_.FullName.Substring((Get-Location).Path.Length + 1) }
} else {
    Write-Host "::warning::$pkgSrc does not exist, no package was produced"
}

# --- AppX assets ---
./platforms/xbox/Generate-Assets.ps1 -InputPng res/icon.png -OutputDir "$buildDir/Assets"
exit 0
