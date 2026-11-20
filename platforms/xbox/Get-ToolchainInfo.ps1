[CmdletBinding()]
param([switch]$AsJson)

$ErrorActionPreference = 'Stop'

function Invoke-CheckedText {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $output = & $Executable @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw ("Command failed with exit code " + $exitCode + ": " + $Executable + " " + ($Arguments -join ' '))
    }
    return (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
}

$programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
if ([string]::IsNullOrWhiteSpace($programFilesX86)) {
    throw 'ProgramFiles(x86) is not defined; cannot locate the Windows build toolchain.'
}

$vswhereCandidates = @(
    (Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe')
)
$vswhere = $vswhereCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $vswhere) {
    throw 'vswhere.exe was not found in the standard Visual Studio Installer locations.'
}

# Do not use -latest here. It can select a newer VS instance that does not contain the UWP C++
# workload while an older, usable UWP instance is installed. Enumerate every matching instance,
# then select the newest complete instance for which CMake has a matching generator.
$vswhereArgs = @(
    '-all',
    '-products', '*',
    '-requires', 'Microsoft.VisualStudio.ComponentGroup.UWP.VC',
    '-format', 'json',
    '-utf8'
)
$vsJson = Invoke-CheckedText -Executable $vswhere -Arguments $vswhereArgs
if ([string]::IsNullOrWhiteSpace($vsJson)) {
    throw 'vswhere returned no Visual Studio instances with the UWP C++ component group.'
}
$vsInstances = @(ConvertFrom-Json -InputObject $vsJson)
if ($vsInstances.Count -eq 0) {
    throw 'No Visual Studio instance with the UWP C++ component group was found.'
}

$cmakeCommand = Get-Command cmake -ErrorAction Stop | Select-Object -First 1
$cmakeExe = $cmakeCommand.Source
if ([string]::IsNullOrWhiteSpace($cmakeExe)) { $cmakeExe = $cmakeCommand.Definition }
$cmakeHelp = Invoke-CheckedText -Executable $cmakeExe -Arguments @('--help')
$cmakeVersionText = Invoke-CheckedText -Executable $cmakeExe -Arguments @('--version')
if ($cmakeVersionText -notmatch '(?m)^cmake version\s+([^\s]+)') {
    throw ("Could not parse the installed CMake version: " + $cmakeVersionText)
}
$cmakeVersion = $Matches[1]

$rustcCommand = Get-Command rustc -ErrorAction Stop | Select-Object -First 1
$rustcExe = $rustcCommand.Source
if ([string]::IsNullOrWhiteSpace($rustcExe)) { $rustcExe = $rustcCommand.Definition }
$rustVersionText = Invoke-CheckedText -Executable $rustcExe -Arguments @('--version', '--verbose')
if ($rustVersionText -notmatch '(?m)^release:\s*(\S+)') {
    throw ("Could not parse the installed Rust compiler version: " + $rustVersionText)
}
$rustVersion = $Matches[1]

$windowsKitsRoot = Join-Path $programFilesX86 'Windows Kits\10'
$sdkIncludeRoot = Join-Path $windowsKitsRoot 'Include'
$sdkLibRoot = Join-Path $windowsKitsRoot 'Lib'
if (-not (Test-Path -LiteralPath $sdkIncludeRoot) -or -not (Test-Path -LiteralPath $sdkLibRoot)) {
    throw ("Windows 10/11 SDK directories were not found under " + $windowsKitsRoot)
}

$sdkCandidates = @(
    Get-ChildItem -LiteralPath $sdkIncludeRoot -Directory |
        Where-Object {
            $_.Name -match '^10\.0\.\d+\.\d+$' -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'um\Windows.h')) -and
            (Test-Path -LiteralPath (Join-Path (Join-Path $sdkLibRoot $_.Name) 'um\x64\kernel32.lib')) -and
            (Test-Path -LiteralPath (Join-Path (Join-Path $sdkLibRoot $_.Name) 'ucrt\x64\ucrt.lib'))
        } |
        Sort-Object { [version]$_.Name } -Descending
)
if ($sdkCandidates.Count -eq 0) {
    throw 'No complete x64 Windows SDK installation was found (UM and UCRT headers/libraries are required).'
}

$selected = $null
$orderedInstances = @(
    $vsInstances |
        Where-Object {
            $_.installationPath -and
            $_.installationVersion -and
            (Test-Path -LiteralPath $_.installationPath)
        } |
        Sort-Object { [version]$_.installationVersion } -Descending
)

foreach ($instance in $orderedInstances) {
    $completeProperty = $instance.PSObject.Properties['isComplete']
    if ($completeProperty -and -not $instance.isComplete) { continue }

    $launchableProperty = $instance.PSObject.Properties['isLaunchable']
    if ($launchableProperty -and -not $instance.isLaunchable) { continue }

    $vsVersion = [version]$instance.installationVersion
    $generator = $null
    foreach ($line in ($cmakeHelp -split '\r?\n')) {
        if ($line -match '^\s*\*?\s*(Visual Studio\s+(\d+)\s+\d{4})\s*=') {
            if ([int]$Matches[2] -eq $vsVersion.Major) {
                $generator = $Matches[1].Trim()
                break
            }
        }
    }
    if (-not $generator) { continue }

    # Map the Visual Studio major version to its CMake platform-toolset name.
    $toolsetName = switch ($vsVersion.Major) {
        18 { 'v145' }
        17 { 'v143' }
        16 { 'v142' }
        15 { 'v141' }
        default { $null }
    }
    if (-not $toolsetName) { continue }

    $msvcRoot = Join-Path $instance.installationPath 'VC\Tools\MSVC'
    if (-not (Test-Path -LiteralPath $msvcRoot)) { continue }

    $msvcCandidates = @(
        Get-ChildItem -LiteralPath $msvcRoot -Directory |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
            Sort-Object { [version]$_.Name } -Descending
    )
    foreach ($msvc in $msvcCandidates) {
        $clPath = Join-Path $msvc.FullName 'bin\Hostx64\x64\cl.exe'
        $dumpbinPath = Join-Path $msvc.FullName 'bin\Hostx64\x64\dumpbin.exe'
        if ((Test-Path -LiteralPath $clPath) -and (Test-Path -LiteralPath $dumpbinPath)) {
            $selected = [pscustomobject]@{
                Instance = $instance
                VisualStudioVersion = $vsVersion
                Generator = $generator
                ToolsetName = $toolsetName
                Msvc = $msvc
                ClPath = $clPath
                DumpbinPath = $dumpbinPath
                Sdk = $sdkCandidates[0]
            }
            break
        }
    }
    if ($selected) { break }
}

if (-not $selected) {
    throw 'No complete UWP-capable Visual Studio instance matched an installed CMake generator, MSVC x64 compiler, and Windows SDK.'
}

$sdlPinFile = Join-Path $PSScriptRoot 'sdl3-uwp-commit.txt'
if (-not (Test-Path -LiteralPath $sdlPinFile)) {
    throw ("Pinned SDL3-UWP commit file is missing: " + $sdlPinFile)
}
$sdlCommit = (Get-Content -LiteralPath $sdlPinFile -Raw).Trim()
if ($sdlCommit -notmatch '^[0-9a-f]{40}$') {
    throw ("The SDL3-UWP pin must be a full 40-character Git commit SHA; found: '" + $sdlCommit + "'")
}

$cacheVersion = if ($env:CACHE_VERSION) { $env:CACHE_VERSION } else { 'v2' }

# Cache only the outputs produced by the exact configuration logic that created them. Source-code
# edits are handled incrementally by Cache-Mtimes.ps1; changes to the build/cache/patch logic must
# instead select a new cache namespace.
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$cacheConfigFiles = @(
    (Join-Path $PSScriptRoot 'Get-ToolchainInfo.ps1'),
    (Join-Path $PSScriptRoot 'ci.ps1'),
    (Join-Path $PSScriptRoot 'Cache-Mtimes.ps1'),
    (Join-Path $PSScriptRoot 'code-mods.txt'),
    (Join-Path $PSScriptRoot 'xbox-project.cmake'),
    (Join-Path $PSScriptRoot 'xbox-mods.cmake'),
    (Join-Path $repoRoot 'cmake/toolchains/xbox-uwp-x64.cmake')
)
$cacheConfigFiles += @(
    Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter 'Apply-Patches*.ps1' |
        Sort-Object Name |
        ForEach-Object { $_.FullName }
)
$cacheConfigHashes = @()
foreach ($configFile in $cacheConfigFiles) {
    if (-not (Test-Path -LiteralPath $configFile)) {
        throw ("Cache configuration input is missing: " + $configFile)
    }
    $relativePath = $configFile.Substring($repoRoot.Length).TrimStart('\', '/').Replace('\', '/')
    $configHash = (Get-FileHash -LiteralPath $configFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $cacheConfigHashes += ("config:" + $relativePath + "=" + $configHash)
}

$signatureParts = @(
    "cache=$cacheVersion",
    'target=windowsstore-x64',
    "generator=$($selected.Generator)",
    "vs-instance=$($selected.Instance.instanceId)",
    "vs-version=$($selected.Instance.installationVersion)",
    "vs-path=$($selected.Instance.installationPath)",
    "msvc-toolset=$($selected.ToolsetName)",
    "msvc-version=$($selected.Msvc.Name)",
    "windows-sdk=$($selected.Sdk.Name)",
    "cmake=$cmakeVersion",
    "rust=$rustVersion",
    "sdl3-uwp=$sdlCommit",
    'configuration=RelWithDebInfo'
) + $cacheConfigHashes
$signature = $signatureParts -join [Environment]::NewLine
$signatureBytes = [Text.Encoding]::UTF8.GetBytes($signature)
$sha256 = [Security.Cryptography.SHA256]::HashData($signatureBytes)
$fingerprint = [Convert]::ToHexString($sha256).ToLowerInvariant()

$info = [pscustomobject]@{
    VisualStudioPath = $selected.Instance.installationPath
    VisualStudioVersion = $selected.Instance.installationVersion
    VisualStudioInstanceId = $selected.Instance.instanceId
    CMakeGenerator = $selected.Generator
    MsvcToolsetName = $selected.ToolsetName
    MsvcToolsetVersion = $selected.Msvc.Name
    MsvcCompilerPath = $selected.ClPath
    DumpbinPath = $selected.DumpbinPath
    WindowsSdkVersion = $selected.Sdk.Name
    CMakeVersion = $cmakeVersion
    RustVersion = $rustVersion
    Sdl3UwpCommit = $sdlCommit
    CacheFingerprint = $fingerprint
    CachePrefix = "xbox-uwp-$cacheVersion-$fingerprint-"
}

if ($AsJson) {
    $info | ConvertTo-Json -Compress -Depth 4
} else {
    $info | Format-List
}
