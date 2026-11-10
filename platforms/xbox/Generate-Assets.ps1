<#
.SYNOPSIS
  Generates the AppX tile/logo PNGs for the Xbox build from res/icon.png.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File platforms/xbox/Generate-Assets.ps1 -InputPng res/icon.png -OutputDir build/xbox-uwp-x64/Assets
#>
param(
    [Parameter(Mandatory = $true)][string]$InputPng,
    [Parameter(Mandatory = $true)][string]$OutputDir
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path $InputPng)) { throw "Input image not found: $InputPng" }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$source = [System.Drawing.Image]::FromFile((Resolve-Path $InputPng))

function New-Asset([string]$Name, [int]$Width, [int]$Height) {
    $bitmap = New-Object System.Drawing.Bitmap($Width, $Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $graphics.Clear([System.Drawing.Color]::Transparent)

    # Fit the icon inside the asset, keeping its aspect ratio and centering it.
    $scale = [Math]::Min($Width / $source.Width, $Height / $source.Height)
    $drawWidth = [int]($source.Width * $scale)
    $drawHeight = [int]($source.Height * $scale)
    $x = [int](($Width - $drawWidth) / 2)
    $y = [int](($Height - $drawHeight) / 2)
    $graphics.DrawImage($source, $x, $y, $drawWidth, $drawHeight)

    $bitmap.Save((Join-Path $OutputDir $Name), [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose()
    $bitmap.Dispose()
}

New-Asset 'StoreLogo.png' 50 50
New-Asset 'Square44x44Logo.png' 44 44
New-Asset 'Square150x150Logo.png' 150 150
New-Asset 'Wide310x150Logo.png' 310 150
New-Asset 'SplashScreen.png' 620 300

$source.Dispose()
Write-Host "Generated Xbox assets in $OutputDir"
