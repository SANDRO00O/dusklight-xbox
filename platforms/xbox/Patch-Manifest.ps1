<#
.SYNOPSIS
  Adds the capabilities / file type associations the Xbox build needs to the AppX manifest that
  CMake's WindowsStore support generated.

  CMake (cmVisualStudio10TargetGenerator, WriteMissingFilesWS10_0) writes a default manifest, when the
  target has no *.appxmanifest source, to <build>/CMakeFiles/<target>.dir/package.appxManifest
  (Identity Publisher="CN=CMake", no <Capabilities> at all). Build 1c7ce4d8's installed manifest
  confirmed none of our additions were in the package, because the first version of this script looked
  for the file next to dusklight.vcxproj.

  Why the additions: a path returned by the FileOpenPicker for a file on a USB drive (E:\...) cannot be
  opened with Win32 (CreateFile2 fails with error 5). A UWP app can open files on removable storage by
  path only when its manifest declares
    * the removableStorage capability, and
    * a file type association for the file's extension.
  broadFileSystemAccess is added as well (RetroArch's UWP build declares the same three things). The
  game also falls back to the StorageFile handle (xbox_file_picker.cpp) when the path stays denied.

  Identity/Publisher are left untouched, so the package keeps the identity CMake generated and the
  signing certificate still matches. Idempotent. Called by ci.ps1 right before the build.
#>
param(
    [string]$BuildDir = 'build/xbox-uwp-x64'
)

$ErrorActionPreference = 'Stop'

function Find-Manifest([string]$Dir) {
    if (-not (Test-Path $Dir)) { return $null }
    Get-ChildItem -Path $Dir -Recurse -File -Filter 'package.appxmanifest' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](_deps|ext)[\\/]' }
}

# 1) where CMake writes it: <build>/CMakeFiles/dusklight.dir/package.appxManifest
$candidates = @(Find-Manifest (Join-Path $BuildDir 'CMakeFiles/dusklight.dir'))
# 2) anywhere else in the build tree
if ($candidates.Count -eq 0) { $candidates = @(Find-Manifest $BuildDir) }
Write-Host ('manifest candidates: ' + (($candidates | ForEach-Object { $_.FullName }) -join '; '))
$manifest = $candidates | Sort-Object { if ($_.FullName -match 'dusklight') { 0 } else { 1 } } | Select-Object -First 1
if (-not $manifest) { throw "package.appxManifest not found under $BuildDir" }

Write-Host "Patching manifest: $($manifest.FullName)"
$text = [System.IO.File]::ReadAllText($manifest.FullName)
$original = $text

$uapNs = 'http://schemas.microsoft.com/appx/manifest/uap/windows10'
$rescapNs = 'http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities'

# --- namespaces ---
$rootMatch = [regex]::Match($text, '<Package\b')
if (-not $rootMatch.Success) { throw 'No <Package> element in the manifest' }
if ($text -notmatch 'xmlns:uap=') {
    $text = $text.Insert($rootMatch.Index + $rootMatch.Length, " xmlns:uap=`"$uapNs`"")
}
if ($text -notmatch 'xmlns:rescap=') {
    $text = $text.Insert($rootMatch.Index + $rootMatch.Length, " xmlns:rescap=`"$rescapNs`"")
}
$ign = [regex]::Match($text, 'IgnorableNamespaces="([^"]*)"')
if ($ign.Success) {
    $names = @($ign.Groups[1].Value -split '\s+' | Where-Object { $_ })
    foreach ($n in 'uap', 'rescap') { if ($names -notcontains $n) { $names += $n } }
    $text = $text.Substring(0, $ign.Index) + 'IgnorableNamespaces="' + ($names -join ' ') + '"' + $text.Substring($ign.Index + $ign.Length)
} else {
    $m = [regex]::Match($text, '<Package\b')
    $text = $text.Insert($m.Index + $m.Length, ' IgnorableNamespaces="uap rescap"')
}

# --- capabilities ---
$caps = @(
    @{ Name = 'removableStorage';        Line = '<uap:Capability Name="removableStorage" />' },
    @{ Name = 'broadFileSystemAccess';   Line = '<rescap:Capability Name="broadFileSystemAccess" />' }
)
$missing = @($caps | Where-Object { $text -notmatch ('Name="' + $_.Name + '"') })
if ($missing.Count -gt 0) {
    $block = ($missing | ForEach-Object { '    ' + $_.Line }) -join "`r`n"
    if ($text -match '</Capabilities>') {
        $text = [regex]::Replace($text, '</Capabilities>', ($block + "`r`n  </Capabilities>"), 1)
    } elseif ($text -match '<Capabilities\s*/>') {
        $text = [regex]::Replace($text, '<Capabilities\s*/>', ("<Capabilities>`r`n" + $block + "`r`n  </Capabilities>"), 1)
    } else {
        $text = [regex]::Replace($text, '</Package>', ("  <Capabilities>`r`n" + $block + "`r`n  </Capabilities>`r`n</Package>"), 1)
    }
}

# --- file type associations (required to open files on removable storage by path) ---
if ($text -notmatch 'windows\.fileTypeAssociation') {
    $exts = '.iso', '.gcm', '.ciso', '.gcz', '.nfs', '.rvz', '.wbfs', '.wia', '.tgc'
    $types = ($exts | ForEach-Object { "            <uap:FileType>$_</uap:FileType>" }) -join "`r`n"
    $ext = @"
      <Extensions>
        <uap:Extension Category="windows.fileTypeAssociation">
          <uap:FileTypeAssociation Name="discimage">
            <uap:SupportedFileTypes>
$types
            </uap:SupportedFileTypes>
          </uap:FileTypeAssociation>
        </uap:Extension>
      </Extensions>
"@
    if ($text -match '<Extensions>') {
        Write-Host '::warning::manifest already has an <Extensions> element; file type association NOT added'
    } elseif ($text -match '</Application>') {
        $text = [regex]::Replace($text, '</Application>', ($ext.TrimEnd() + "`r`n    </Application>"), 1)
    } else {
        Write-Host '::warning::no </Application> in the manifest; file type association NOT added'
    }
}

if ($text -ne $original) {
    [System.IO.File]::WriteAllText($manifest.FullName, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host 'Manifest patched.'
} else {
    Write-Host 'Manifest already patched.'
}

# --- branded tile / logo / splash images ---------------------------------------------------------
# The manifest CMake generated points at CMake's own placeholder PNGs (Logo.png, SmallLogo.png,
# StoreLogo.png, SplashScreen.png ...) that it writes next to the manifest and adds to the project as
# image items, i.e. they are already in the package's resource index (PRI). The installed app therefore
# showed CMake's generic splash. Overwrite those files in place with the ones Generate-Assets.ps1 made from
# res/icon.png: same names, same items, same PRI entries, only the pixels change. (Adding new image files
# or pointing the manifest at new paths risks an empty resource index, the fork 999sian/dusklight got
# install error 0x80070002 from that.)
$assetDir = Join-Path $BuildDir 'Assets'
# Generate the images here, so ci.ps1 needs no extra step (Generate-Assets.ps1 runs again at the end of ci.ps1).
try {
    & (Join-Path $PSScriptRoot 'Generate-Assets.ps1') -InputPng (Join-Path $PSScriptRoot '../../res/icon.png') -OutputDir $assetDir
} catch {
    Write-Host "::warning::Generate-Assets.ps1 failed, the package keeps CMake's placeholder images: $_"
}
$manifestDir = $manifest.DirectoryName
$imageRefs = @(
    @{ Rx = '<Logo>\s*([^<]+?)\s*</Logo>';                  Gen = 'StoreLogo.png' },
    @{ Rx = 'Square150x150Logo="([^"]+)"';                   Gen = 'Square150x150Logo.png' },
    @{ Rx = 'Square44x44Logo="([^"]+)"';                     Gen = 'Square44x44Logo.png' },
    @{ Rx = 'Wide310x150Logo="([^"]+)"';                     Gen = 'Wide310x150Logo.png' },
    @{ Rx = '<uap:SplashScreen\b[^>]*?\bImage="([^"]+)"';    Gen = 'SplashScreen.png' }
)
Write-Host "images next to the manifest ($manifestDir):"
Get-ChildItem -Path $manifestDir -File -Filter '*.png' -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host ('  {0,8:N0}  {1}' -f $_.Length, $_.Name) }
foreach ($r in $imageRefs) {
    $m = [regex]::Match($text, $r.Rx)
    if (-not $m.Success) { Write-Host "image ref for $($r.Gen): not in the manifest, skipped"; continue }
    $ref = $m.Groups[1].Value
    $target = Join-Path $manifestDir ($ref -replace '\\', '/')
    $generated = Join-Path $assetDir $r.Gen
    if (-not (Test-Path $generated)) { Write-Host "::warning::generated image missing: $generated"; continue }
    if (-not (Test-Path $target)) { Write-Host "::warning::manifest references '$ref' but $target does not exist; left alone"; continue }
    Copy-Item -Force -Path $generated -Destination $target
    Write-Host ("branded image: {0} <- {1}" -f $ref, $r.Gen)
}

# Validate it is still well-formed XML.
[xml]$check = Get-Content -Raw -Path $manifest.FullName
Write-Host '--- manifest after patching ---'
Get-Content -Path $manifest.FullName
Write-Host '--- end of manifest ---'
