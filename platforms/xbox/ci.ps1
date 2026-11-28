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
$sdlPinFile = 'platforms/xbox/sdl3-uwp-commit.txt'
if (-not (Test-Path $sdlPinFile)) { throw "Pinned SDL3-UWP commit file is missing: $sdlPinFile" }
$sdlUwpCommit = (Get-Content -Raw $sdlPinFile).Trim()
if ($sdlUwpCommit -notmatch '^[0-9a-f]{40}$') { throw "Invalid SDL3-UWP commit in $sdlPinFile" }
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

# The post-link step (symgen manifest --embed, cmake/SymbolManifest.cmake) patches the descriptor in the PE
# section .symdbh: rva 0 = nothing embedded (the game then logs "no symbol manifest embedded" and no native mod
# can hook a function by name).
function Get-Symdb([string]$Path) {
    $r = [pscustomobject]@{ Found = $false; Rva = [uint64]0; Size = [uint64]0; Text = '' }
    try {
        $b = [System.IO.File]::ReadAllBytes($Path)
        $pe = [BitConverter]::ToInt32($b, 0x3C)
        $nsec = [BitConverter]::ToUInt16($b, $pe + 6)
        $optSize = [BitConverter]::ToUInt16($b, $pe + 20)
        $sec = $pe + 24 + $optSize
        $names = @()
        for ($k = 0; $k -lt $nsec; $k++) {
            $o = $sec + 40 * $k
            $name = [System.Text.Encoding]::ASCII.GetString($b, $o, 8).TrimEnd([char]0)
            $names += $name
            if ($name -eq '.symdbh') {
                $raw = [BitConverter]::ToUInt32($b, $o + 20)
                $r.Found = $true
                $magic = [BitConverter]::ToUInt64($b, $raw)
                $r.Rva = [BitConverter]::ToUInt64($b, $raw + 8)
                $r.Size = [BitConverter]::ToUInt64($b, $raw + 16)
                $r.Text = ('.symdbh magic=0x{0:X} rva=0x{1:X} size={2:N0}; sections so far: {3}' -f $magic, $r.Rva, $r.Size, ($names -join ' '))
                return $r
            }
        }
        $r.Text = 'NO .symdbh section; sections: ' + ($names -join ' ')
    } catch { $r.Text = "unreadable: $_" }
    return $r
}

# Throw the package away and let the build produce it again (the layout copies dusklight.exe again when it is newer).
function Invoke-Repackage([string]$LogName) {
    $pkgDir = Join-Path $buildDir 'AppPackages'
    $pkgBak = Join-Path $buildDir 'AppPackages.bak'
    if (-not (Test-Path $pkgDir)) { return $false }
    Remove-Item -Recurse -Force $pkgBak -ErrorAction SilentlyContinue
    Move-Item -Path $pkgDir -Destination $pkgBak
    cmake --build $buildDir --config $config --target dusklight 2>&1 | Tee-Object -FilePath $LogName | Out-Null
    $rc = $LASTEXITCODE
    if (($rc -ne 0) -or (-not (Test-Path $pkgDir))) {
        Write-Host "::warning::repackaging ($LogName) failed (exit code $rc), keeping the previous package"
        Remove-Item -Recurse -Force $pkgDir -ErrorAction SilentlyContinue
        Move-Item -Path $pkgBak -Destination $pkgDir
        return $false
    }
    Remove-Item -Recurse -Force $pkgBak -ErrorAction SilentlyContinue
    return $true
}

# Copy the manifest blob (the bytes the .symdbh descriptor points at) out of an exe that symgen embedded it into.
# Returns $true when $Out holds a blob that starts with the symgen magic.
function Export-Symdb([string]$Exe, [string]$Out) {
    $d = Get-Symdb $Exe
    if ((-not $d.Found) -or $d.Rva -eq 0 -or $d.Size -eq 0) { return $false }
    $b = [System.IO.File]::ReadAllBytes($Exe)
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    $nsec = [BitConverter]::ToUInt16($b, $pe + 6)
    $optSize = [BitConverter]::ToUInt16($b, $pe + 20)
    $sec = $pe + 24 + $optSize
    for ($k = 0; $k -lt $nsec; $k++) {
        $o = $sec + 40 * $k
        $vsize = [uint64][BitConverter]::ToUInt32($b, $o + 8)
        $va = [uint64][BitConverter]::ToUInt32($b, $o + 12)
        $rawSize = [uint64][BitConverter]::ToUInt32($b, $o + 16)
        $raw = [int64][BitConverter]::ToUInt32($b, $o + 20)
        $len = if ($vsize -gt $rawSize) { $vsize } else { $rawSize }
        if ($d.Rva -ge $va -and $d.Rva -lt ($va + $len)) {
            $off = $raw + [int64]($d.Rva - $va)
            $size = [int64]$d.Size
            if (($off + $size) -gt $b.Length) { return $false }
            $blob = [byte[]]::new([int]$size)
            [Array]::Copy($b, $off, $blob, [int64]0, $size)
            if ([System.Text.Encoding]::ASCII.GetString($blob, 0, 6) -ne 'SYMGEN') { return $false }
            [System.IO.File]::WriteAllBytes($Out, $blob)
            return $true
        }
    }
    return $false
}

# --- Diagnostics: what does this runner actually have? ---
Write-Host '::group::Tool versions'
cmake --version
rustc --version 2>&1
cargo --version 2>&1
git --version
Write-Host '::endgroup::'

# Use the exact toolchain object produced by the cache-key step. This prevents a second
# discovery from selecting a different Visual Studio instance or compiler within the same job.
# For direct local invocation, resolve it here as a fallback.
$toolchainInfo = $null
try {
    if (-not [string]::IsNullOrWhiteSpace($env:XBOX_TOOLCHAIN_JSON)) {
        $toolchainInfo = $env:XBOX_TOOLCHAIN_JSON | ConvertFrom-Json
    } else {
        $toolchainInfoScript = 'platforms/xbox/Get-ToolchainInfo.ps1'
        if (-not (Test-Path $toolchainInfoScript)) { throw "Toolchain resolver is missing: $toolchainInfoScript" }
        $toolchainJson = & $toolchainInfoScript -AsJson
        if (-not $toolchainJson) { throw 'Toolchain resolver returned no data.' }
        $toolchainInfo = ($toolchainJson -join [Environment]::NewLine) | ConvertFrom-Json
    }
    if (-not $toolchainInfo.CMakeGenerator -or -not $toolchainInfo.MsvcToolsetVersion -or -not $toolchainInfo.WindowsSdkVersion) {
        throw 'Resolved toolchain data is incomplete.'
    }
    $toolchainInfo | ConvertTo-Json -Compress -Depth 4 | Out-File -FilePath 'vswhere.log' -Encoding utf8
    Write-Host '--- Selected UWP toolchain ---'
    Write-Host ("Visual Studio: {0} | {1}" -f $toolchainInfo.VisualStudioVersion, $toolchainInfo.VisualStudioPath)
    Write-Host ("CMake generator: {0}" -f $toolchainInfo.CMakeGenerator)
    Write-Host ("MSVC: {0} {1}" -f $toolchainInfo.MsvcToolsetName, $toolchainInfo.MsvcToolsetVersion)
    Write-Host ("Windows SDK: {0}" -f $toolchainInfo.WindowsSdkVersion)
    Write-Host ("CMake: {0} | Rust: {1}" -f $toolchainInfo.CMakeVersion, $toolchainInfo.RustVersion)
    Write-Host ("SDL3-UWP commit: {0}" -f $toolchainInfo.Sdl3UwpCommit)
} catch {
    $toolchainInfo = $null
    Write-Host ("::warning::Could not resolve an explicit UWP toolchain; CMake will use its normal generator selection and this run must not use a build cache. " + $_.Exception.Message)
    ($_ | Out-String) | Out-File -FilePath 'vswhere.log' -Encoding utf8
}

# --- Fetch the UWP SDL3 fork ---
# build/ext is part of the CI cache, so on a cache hit the clone (with its original file mtimes) is
# reused and SDL is not rebuilt.
if (-not (Test-Path (Join-Path $sdlUwpDir '.git'))) {
    if (Test-Path $sdlUwpDir) {
        Remove-Item -Recurse -Force $sdlUwpDir
    }
    Write-Host "Cloning $sdlUwpRepo ($sdlUwpBranch) into $sdlUwpDir"
    New-Item -ItemType Directory -Force -Path (Split-Path $sdlUwpDir) | Out-Null
    git clone --depth 1 --branch $sdlUwpBranch $sdlUwpRepo $sdlUwpDir 2>&1 | Tee-Object -FilePath sdl-clone.log | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Show-Failure 'SDL3-UWP CLONE' 'sdl-clone.log' $LASTEXITCODE
        exit $LASTEXITCODE
    }
}

# The clone is cached, but the dependency is not allowed to float with its branch. Fetch the pinned
# commit when it is not already present, then hard-reset the cached checkout to that exact revision.
& git -C $sdlUwpDir cat-file -e ($sdlUwpCommit + '^{commit}') 2>$null
$hasPinnedSdlCommit = ($LASTEXITCODE -eq 0)
if (-not $hasPinnedSdlCommit) {
    git -C $sdlUwpDir fetch --depth 1 origin $sdlUwpCommit 2>&1 | Tee-Object -FilePath sdl-clone.log -Append | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Show-Failure 'SDL3-UWP FETCH PINNED COMMIT' 'sdl-clone.log' $LASTEXITCODE
        exit $LASTEXITCODE
    }
}
git -C $sdlUwpDir reset --hard $sdlUwpCommit 2>&1 | Tee-Object -FilePath sdl-clone.log -Append | Out-Null
if ($LASTEXITCODE -ne 0) {
    Show-Failure 'SDL3-UWP CHECKOUT PINNED COMMIT' 'sdl-clone.log' $LASTEXITCODE
    exit $LASTEXITCODE
}

$sdlHead = (git -C $sdlUwpDir rev-parse HEAD).Trim()
Write-Host "SDL3-uwp HEAD: $sdlHead"
if ($sdlHead -ne $sdlUwpCommit) {
    Write-Host "::error::SDL3-UWP checkout does not match pinned commit $sdlUwpCommit"
    exit 1
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

# --- Performance: Dusk bloom / depth of field off by default on Xbox + perf-diag.log (frame drops that depend on the view) ---
./platforms/xbox/Apply-Patches-Perf.ps1 2>&1 | Tee-Object -FilePath patches.log -Append
if ($LASTEXITCODE -ne 0) {
    Write-Host '################ PERF PATCHING FAILED: an anchor in the game sources did not match (see patches.log) ################'
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
# Same for the symbol manifest blob (symbols/dusklight.symdb, see "Symbol manifest for native mods" below).
$symdbFile = Join-Path $buildDir 'dusklight.symdb'
'no symbol manifest in this build' | Out-File -FilePath $symdbFile -Encoding ascii

# --- Configure ---
# Pin the Visual Studio instance, generator, MSVC toolset and SDK. CMake otherwise may choose a
# different Visual Studio instance when multiple installations are present, making a restored
# CMake/MSBuild cache unsafe. If discovery failed, do not guess: use CMake's default selection.
# FETCHCONTENT_SOURCE_DIR_SDL points Aurora at the exact pinned UWP SDL checkout.
'configure' | Out-File -FilePath 'ci-stage.txt' -Encoding ascii
$cmakeArgs = @('-S', '.', '-B', $buildDir)
if ($toolchainInfo) {
    $cmakeArgs += @('-G', $toolchainInfo.CMakeGenerator)
    $cmakeArgs += @('-A', "x64,version=$($toolchainInfo.WindowsSdkVersion)")
    $cmakeArgs += @('-T', "$($toolchainInfo.MsvcToolsetName),version=$($toolchainInfo.MsvcToolsetVersion),host=x64")
    $cmakeArgs += "-DCMAKE_GENERATOR_INSTANCE=$($toolchainInfo.VisualStudioPath)"
    Write-Host ("Using explicit CMake toolchain: {0}; {1}; SDK {2}" -f $toolchainInfo.CMakeGenerator, $toolchainInfo.MsvcToolsetVersion, $toolchainInfo.WindowsSdkVersion)
} else {
    $cmakeArgs += @('-A', 'x64')
}
$cmakeArgs += @("-DCMAKE_TOOLCHAIN_FILE=$toolchain", "-DFETCHCONTENT_SOURCE_DIR_SDL=$sdlUwpDir")
Write-Host ("Configuring: cmake " + ($cmakeArgs -join ' '))
$sw = [Diagnostics.Stopwatch]::StartNew()
& cmake @cmakeArgs 2>&1 | Tee-Object -FilePath configure.log | Out-Null
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

# --- funchook (native mods): hook functions that start with a short jump or end inside the patched bytes ---
# Not fatal: without it the affected hooks fail (logged "funchook failed ... prepare=5/7") and everything else works.
./platforms/xbox/Apply-Patches-Funchook.ps1 -BuildDir $buildDir 2>&1 | Tee-Object -FilePath patches.log -Append
if ($LASTEXITCODE -ne 0) {
    Write-Host '::warning::funchook patch (Apply-Patches-Funchook.ps1) failed, hooks that need it will fail on the console'
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

# --- Native mods: is the symbol manifest really inside the exe? ---
# FOUND ON HARDWARE: "no symbol manifest embedded", so ~400 by-name hooks of Twilit Essentials / Deferred Fog did
# not resolve. The POST_BUILD step of CMake should have embedded it. When the built exe still has an empty
# descriptor, run symgen here (output in Assets/symgen-embed.log) and rebuild the package from that exe.
$manifestStatus = 'not checked'
try {
    $exeBuilt = Join-Path $buildDir "$config/dusklight.exe"
    $cacheTxt = Join-Path $buildDir 'CMakeCache.txt'
    if (Test-Path $exeBuilt) {
        $sd = Get-Symdb $exeBuilt
        Write-Host ("symbol manifest in the built exe: " + $sd.Text)
        $manifestStatus = 'embedded by the build (rva=0x{0:X})' -f $sd.Rva
        if ($sd.Found -and $sd.Rva -eq 0) {
            $symgenHit = if (Test-Path $cacheTxt) { Select-String -Path $cacheTxt -Pattern '^SYMGEN_EXE:[A-Z]+=(.+)$' | Select-Object -First 1 } else { $null }
            $pdbFile = Get-ChildItem -Path (Join-Path $buildDir $config) -Filter 'dusklight.pdb' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            $embedAssets = Join-Path $buildDir 'Assets'
            New-Item -ItemType Directory -Force -Path $embedAssets | Out-Null
            $embedLog = Join-Path $embedAssets 'symgen-embed.log'
            if ($symgenHit -and (Test-Path -LiteralPath $symgenHit.Matches[0].Groups[1].Value) -and $pdbFile) {
                $symgenExe = $symgenHit.Matches[0].Groups[1].Value
                Write-Host "::warning::the built exe has an EMPTY symbol manifest, running symgen manually ($symgenExe)"
                $out = & $symgenExe manifest --pdb $pdbFile.FullName --embed $exeBuilt 2>&1
                $symgenRc = $LASTEXITCODE
                (@("symgen exit code: $symgenRc", "pdb: $($pdbFile.FullName)") + @($out | ForEach-Object { "$_" })) | Out-File -FilePath $embedLog -Encoding utf8
                $sd2 = Get-Symdb $exeBuilt
                Write-Host ("symbol manifest after the manual embed (symgen exit code {0}): {1}" -f $symgenRc, $sd2.Text)
                if ($sd2.Rva -ne 0) {
                    $manifestStatus = 'EMBEDDED MANUALLY by ci.ps1 (the CMake post-build step had not): ' + $sd2.Text
                    if (Invoke-Repackage 'build-manifest.log') {
                        Write-Host 'package rebuilt from the exe with the symbol manifest'
                    } else {
                        $manifestStatus += ' -- but repackaging failed, the package still has the old exe'
                    }
                } else {
                    $manifestStatus = "symgen ran (exit code $symgenRc) but the descriptor is still empty, see symgen-embed.log"
                }
            } else {
                $manifestStatus = 'built exe has an empty symbol manifest and symgen or the pdb was not found (SYMGEN_EXE: {0}, pdb: {1})' -f ($(if ($symgenHit) { $symgenHit.Matches[0].Groups[1].Value } else { 'unset' })), ($(if ($pdbFile) { $pdbFile.FullName } else { 'missing' }))
                Write-Host "::warning::$manifestStatus"
                $manifestStatus | Out-File -FilePath $embedLog -Encoding utf8
            }
        } elseif (-not $sd.Found) {
            $manifestStatus = 'no .symdbh section in the built exe (descriptor optimised away?)'
            Write-Host "::warning::$manifestStatus"
        }
    } else {
        $manifestStatus = 'no built exe, nothing to check'
    }
} catch {
    $manifestStatus = "check failed: $_"
    Write-Host "::warning::symbol manifest check failed: $_"
}

# --- Symbol manifest for native mods: ship the blob as symbols/dusklight.symdb ---
# FOUND ON HARDWARE (mods-build.log of 2026-11-28): the built exe has the manifest (rva=0x26A8000, 46.4 MB) but the exe
# inside the .msix has none (rva=0, 39.2 MB): MSBuild's AppxPackage step runs BEFORE the post-build step that embeds it.
# The blob is copied into <build>/dusklight.symdb (a deployment-content file, like dusklight.sym) and the package is
# built again below; the game reads it when the exe has no embedded manifest (Apply-Patches-Manifest.ps1).
$symdbReady = $false
$didRepack = $false
try {
    $exeForSymdb = Join-Path $buildDir "$config/dusklight.exe"
    if ((Test-Path $exeForSymdb) -and (Export-Symdb $exeForSymdb $symdbFile)) {
        $symdbReady = $true
        $sdb = Get-Item $symdbFile
        Write-Host ('symbol manifest blob for the package: {0:N0} bytes -> {1}' -f $sdb.Length, $symdbFile)
        $manifestStatus += (' | shipped as symbols/dusklight.symdb ({0:N0} bytes)' -f $sdb.Length)
    } else {
        Write-Host '::warning::could not copy the symbol manifest blob out of the built exe, the package has no manifest'
        $manifestStatus += ' | NOT shipped as symbols/dusklight.symdb (blob not found in the built exe)'
    }
} catch {
    Write-Host "::warning::symbol manifest blob export failed: $_"
}

# --- Symbol table for crash / hang stack traces, then repackage ---
# Everything in this block is best effort: when it fails the first package (placeholder symbol table) stays.
try {
    if (Test-Path $mapFile) {
        ./platforms/xbox/Make-Symbols.ps1 -MapFile $mapFile -OutFile $symFile 2>&1 | Tee-Object -FilePath symbols.log
        $symSize = (Get-Item $symFile).Length
        Write-Host ('symbol table: {0:N0} bytes' -f $symSize)
        $pkgDir = Join-Path $buildDir 'AppPackages'
        $pkgBak = Join-Path $buildDir 'AppPackages.nosyms'
        if ((($symSize -gt 4096) -or $symdbReady) -and (Test-Path $pkgDir)) {
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
                $didRepack = $true
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
                        $entryDb = $zip.Entries | Where-Object { $_.FullName -match 'symbols[/\\]dusklight\.symdb$' } | Select-Object -First 1
                        if ($entryDb) {
                            Write-Host ('{0}: symbols/dusklight.symdb = {1:N0} bytes' -f $_.Name, $entryDb.Length)
                            if ($symdbReady -and $entryDb.Length -lt 4096) { Write-Host "::warning::$($_.Name) still has the placeholder symbol manifest" }
                        } else {
                            Write-Host "::warning::$($_.Name) does not contain symbols/dusklight.symdb"
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

# The block above repackages only when the linker map exists. If it did not run but the manifest blob is ready, do it here.
if ($symdbReady -and (-not $didRepack)) {
    if (Invoke-Repackage 'build-symdb.log') {
        $didRepack = $true
        Write-Host 'package rebuilt with symbols/dusklight.symdb'
    } else {
        $manifestStatus += ' | repackaging for symbols/dusklight.symdb FAILED'
    }
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
if ((Test-Path $exe) -and $toolchainInfo -and (Test-Path -LiteralPath $toolchainInfo.DumpbinPath)) {
    $importsLog = Join-Path $assetsDir 'imports.log'
    & $toolchainInfo.DumpbinPath /nologo /imports $exe 2>&1 | Out-File -FilePath $importsLog -Encoding utf8
    Write-Host '--- imported DLLs of dusklight.exe ---'
    Select-String -Path $importsLog -Pattern '^\s+\S+\.dll\s*$' | ForEach-Object { $_.Line.Trim() } | Sort-Object -Unique | ForEach-Object { '  ' + $_ }
} elseif (Test-Path $exe) {
    Write-Host '::warning::dumpbin.exe could not be resolved, imports.log skipped'
}

# --- Native mods: what ended up in the build and the package? (Assets/mods-build.log) ---
# Best effort. Shows whether native mods were compiled in, the size of the exported symbol list, and whether the
# dusklight.exe inside the .msix is the one the post-link step embedded the symbol manifest into (same size as
# the built exe) and whether the VC runtime DLLs for desktop-built mods are in the package.
try {
    $modsLog = Join-Path $assetsDir 'mods-build.log'
    $lines = @()
    $lines += "FORCE_MODS_OFF=$($env:DUSK_XBOX_FORCE_MODS_OFF)"
    $lines += "symbol manifest: $manifestStatus"
    foreach ($logName in 'build.log', 'build-symbols.log') {
        if (Test-Path $logName) {
            $hits = @(Select-String -Path $logName -Pattern 'Embedding symbol manifest|symgen' | ForEach-Object { $_.Line.Trim() })
            $lines += ("{0}: {1} line(s) mentioning symgen / Embedding symbol manifest" -f $logName, $hits.Count)
            $hits | Select-Object -First 8 | ForEach-Object { $lines += ('    ' + $_) }
        }
    }
    $cache = Join-Path $buildDir 'CMakeCache.txt'
    if (Test-Path $cache) { $lines += (Select-String -Path $cache -Pattern '^(DUSK_ENABLE_CODE_MODS|DUSK_HAS_FUNCHOOK):' | ForEach-Object { $_.Line }) }
    foreach ($def in (Get-ChildItem -Path $buildDir -Recurse -Filter 'dusklight_exports.def' -ErrorAction SilentlyContinue)) {
        $n = (Get-Content $def.FullName | Measure-Object -Line).Lines
        $lines += ("exports def: {0} ({1:N0} lines)" -f $def.FullName, $n)
    }
    foreach ($lib in (Get-ChildItem -Path $buildDir -Recurse -Filter 'dusklight_imports.lib' -ErrorAction SilentlyContinue)) {
        $lines += ("import library: {0} ({1:N0} bytes)" -f $lib.FullName, $lib.Length)
    }
    if (Test-Path $exe) { $lines += ("built exe: {0:N0} bytes" -f (Get-Item $exe).Length); $lines += ("built exe: " + (Get-Symdb $exe).Text) }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Get-ChildItem -Path (Join-Path $buildDir 'AppPackages') -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.msix', '.appx' } | ForEach-Object {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($_.FullName)
        try {
            $e = $zip.Entries | Where-Object { $_.FullName -ieq 'dusklight.exe' } | Select-Object -First 1
            if ($e) { $lines += ("{0}: dusklight.exe in package = {1:N0} bytes" -f $_.Name, $e.Length) }
            if ($e) {
                $tmpExe = Join-Path ([System.IO.Path]::GetTempPath()) 'pkg-dusklight.exe'
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $tmpExe, $true)
                $lines += ("{0}: packaged exe: {1}" -f $_.Name, (Get-Symdb $tmpExe).Text)
                Remove-Item -Force $tmpExe -ErrorAction SilentlyContinue
            }
            $eDb = $zip.Entries | Where-Object { $_.FullName -match 'symbols[/\\]dusklight\.symdb$' } | Select-Object -First 1
            $lines += ("{0}: symbols/dusklight.symdb in package = {1}" -f $_.Name, $(if ($eDb) { ('{0:N0} bytes' -f $eDb.Length) } else { 'MISSING' }))
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
