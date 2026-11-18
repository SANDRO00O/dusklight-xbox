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

  internetClient: without it UWP blocks every outgoing connection, so the online mod catalog (WinHTTP in
  borealis::http) could not be reached.

  expandedResources (restricted capability, the fork 999sian/dusklight declares it too): asks for the
  Game-mode resource budget (more CPU cores, 5 GB instead of 1 GB, full GPU) instead of App mode. Whether the
  console grants it also depends on the package type (Device Portal / Dev Home: "Game").

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
    @{ Name = 'internetClient';          Line = '<Capability Name="internetClient" />' },
    @{ Name = 'removableStorage';        Line = '<uap:Capability Name="removableStorage" />' },
    @{ Name = 'broadFileSystemAccess';   Line = '<rescap:Capability Name="broadFileSystemAccess" />' },
    @{ Name = 'expandedResources';       Line = '<rescap:Capability Name="expandedResources" />' }
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

# --- branded tile / logo / splash images ---------------------------------------------------------
# xbox-project.cmake adds the PNGs generated from res/icon.png (<build>/Assets) to the project as Image
# items that are also deployment content in the package folder Assets\ (the way the fork 999sian/dusklight
# does it, which also keeps them in the PRI index). CMake's own default manifest still points at its
# placeholder PNGs under CMakeFiles\dusklight.dir, which are NOT packaged: the console showed the blue
# manifest background and a square with an X as splash screen. Point the manifest at the packaged images,
# but only for images the project really contains, because a reference to a file that is not in the
# package makes the install fail.
$projFile = Get-ChildItem -Path $BuildDir -File -Filter 'dusklight.vcxproj' -ErrorAction SilentlyContinue | Select-Object -First 1
$projText = if ($projFile) { [System.IO.File]::ReadAllText($projFile.FullName) } else { '' }
function Test-PackagedAsset([string]$Name) {
    # <Image Include="...\Assets\<Name>"> ... <Link>Assets\...</Link> ... </Image>
    return ($projText -match ('(?s)<Image Include="[^"]*Assets[\\/]' + [regex]::Escape($Name) + '">(?:(?!</Image>).)*?<Link>Assets\\'))
}
$imageRefs = @(
    @{ Rx = '(<Logo>)\s*[^<]+?\s*(</Logo>)';                 Asset = 'StoreLogo.png';           Repl = '${1}Assets\StoreLogo.png${2}' },
    @{ Rx = '(Square150x150Logo=")[^"]+(")';                    Asset = 'Square150x150Logo.png';   Repl = '${1}Assets\Square150x150Logo.png${2}' },
    @{ Rx = '(Square44x44Logo=")[^"]+(")';                      Asset = 'Square44x44Logo.png';     Repl = '${1}Assets\Square44x44Logo.png${2}' },
    @{ Rx = '(<uap:SplashScreen\b[^>]*?\bImage=")[^"]+(")';    Asset = 'SplashScreen.png';        Repl = '${1}Assets\SplashScreen.png${2}' }
)
if (-not $projFile) { Write-Host "::warning::dusklight.vcxproj not found under $BuildDir; manifest images left as CMake wrote them" }
$allAssets = $true
foreach ($r in $imageRefs) {
    if (-not (Test-PackagedAsset $r.Asset)) { $allAssets = $false; Write-Host "::warning::Assets\$($r.Asset) is not in the project; manifest image left as CMake wrote it" }
}
if ($projFile -and $allAssets) {
    foreach ($r in $imageRefs) {
        $text = [regex]::Replace($text, $r.Rx, $r.Repl)
        Write-Host "manifest image -> Assets\$($r.Asset)"
    }
    # Same dark colour as the splash image background (Generate-Assets.ps1).
    $text = [regex]::Replace($text, '(BackgroundColor=")#[0-9A-Fa-f]{6}(")', '${1}#10141C${2}')
}

if ($text -ne $original) {
    [System.IO.File]::WriteAllText($manifest.FullName, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host 'Manifest patched.'
} else {
    Write-Host 'Manifest already patched.'
}

# Validate it is still well-formed XML.
[xml]$check = Get-Content -Raw -Path $manifest.FullName
Write-Host '--- manifest after patching ---'
Get-Content -Path $manifest.FullName
Write-Host '--- end of manifest ---'
