<#
.SYNOPSIS
  Adds the capabilities / file type associations the Xbox build needs to the AppX manifest that
  CMake's WindowsStore support generated (Package.appxManifest next to dusklight.vcxproj).

  Why: CMake's default manifest only declares <Capability Name="internetClient"/>. With that, a path
  returned by the FileOpenPicker for a file on a USB drive (E:\...) cannot be opened with Win32
  (CreateFile2 fails with error 5), so the game could not read the disc image. A UWP app can open
  files on removable storage by path only when its manifest declares
    * the removableStorage capability, and
    * a file type association for the file's extension.
  broadFileSystemAccess is added as well (RetroArch's UWP build declares the same three things).

  Identity/Publisher are left untouched, so the package keeps the identity CMake generated and the
  signing certificate still matches. Idempotent. Called by ci.ps1 right before the build.
#>
param(
    [string]$BuildDir = 'build/xbox-uwp-x64'
)

$ErrorActionPreference = 'Stop'

$vcxproj = Get-ChildItem -Path $BuildDir -Filter 'dusklight.vcxproj' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $vcxproj) {
    $vcxproj = Get-ChildItem -Path $BuildDir -Filter 'dusklight.vcxproj' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $vcxproj) { throw "dusklight.vcxproj not found under $BuildDir" }

$manifest = Get-ChildItem -Path $vcxproj.DirectoryName -Filter 'Package.appxmanifest' -File | Select-Object -First 1
if (-not $manifest) { throw "Package.appxManifest not found next to $($vcxproj.FullName)" }

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

# Validate it is still well-formed XML.
[xml]$check = Get-Content -Raw -Path $manifest.FullName
Write-Host '--- manifest after patching ---'
Get-Content -Path $manifest.FullName
Write-Host '--- end of manifest ---'
