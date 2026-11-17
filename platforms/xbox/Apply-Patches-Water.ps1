<#
.SYNOPSIS
  Water refraction on the Xbox (UWP). Called by Apply-Patches-Disc.ps1 from ci.ps1 before configure.

  FOUND ON HARDWARE: the framerate drops to about 30 fps in Ordon Village, and the person testing traced it
  to the water. The game already has the setting game.disableWaterRefraction (it skips the extra
  "invisible" draw lists that produce the refraction effect, see dComIfGd_drawXluListInvisible in
  src/d/d_com_inf_game.cpp), but it is only reachable from the ImGui debug menu (Tools), which cannot be
  used with a controller. Two edits:

  1. src/dusk/settings.cpp: on UWP the default of game.disableWaterRefraction is true (a saved value in
     the config file still wins).
  2. src/dusk/ui/settings.cpp: a "Disable Water Refraction" switch in Settings > Graphics > Rendering, so it
     can be changed from the controller.

  Idempotent (marker dusk_xbox_water). Exits 1 when an anchor does not match exactly once.
  Both patched files must be listed in $alwaysFresh of Cache-Mtimes.ps1.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$script:failed = $false
$utf8 = New-Object System.Text.UTF8Encoding($false)
$marker = 'dusk_xbox_water'

function Patch-Water([string]$Rel, [object[]]$Edits) {
    $path = Join-Path $RepoRoot $Rel
    if (-not (Test-Path $path)) {
        Write-Host "::error::patch target missing: $Rel"
        $script:failed = $true
        return
    }
    $text = [System.IO.File]::ReadAllText($path)
    if ($text.Contains($marker)) {
        Write-Host "already patched: $Rel"
        return
    }
    foreach ($e in $Edits) {
        $count = [regex]::Matches($text, $e.Pattern).Count
        if ($count -ne $e.Expected) {
            Write-Host "::error::patch anchor '$($e.Pattern)' in $Rel matched $count time(s), expected $($e.Expected) (upstream changed?)"
            $script:failed = $true
            return
        }
    }
    foreach ($e in $Edits) {
        $text = [regex]::Replace($text, $e.Pattern, $e.Replacement.Replace('$', '$$'))
    }
    [System.IO.File]::WriteAllText($path, $text, $utf8)
    Write-Host "patched: $Rel ($($Edits.Count) edit(s))"
}

# --- default on ---------------------------------------------------------------------------------
$defaultNew = @'
#ifdef DUSK_XBOX_UWP
        // dusk_xbox_water: water refraction costs too much on the Xbox One S (see Apply-Patches-Water.ps1).
        .disableWaterRefraction {"game.disableWaterRefraction", true},
#else
        .disableWaterRefraction {"game.disableWaterRefraction", false},
#endif
'@
Patch-Water 'src/dusk/settings.cpp' @(
    @{ Pattern = '(?m)^        \.disableWaterRefraction \{"game\.disableWaterRefraction", false\},(?=\r?$)';
       Replacement = $defaultNew.TrimEnd(); Expected = 1 }
)

# --- switch in Settings > Graphics > Rendering --------------------------------------------------
$uiNew = @'
        // dusk_xbox_water: reachable with a controller (the ImGui Tools menu is not).
        config_bool_select(leftPane, rightPane, getSettings().game.disableWaterRefraction,
            {
                .key = "Disable Water Refraction",
                .helpText = "Skip the extra passes that draw the refraction effect of water surfaces. "
                            "Can improve performance a lot in areas with water, such as Ordon Village.",
            });
        config_bool_select(leftPane, rightPane, getSettings().game.enableMapBackground,
'@
Patch-Water 'src/dusk/ui/settings.cpp' @(
    @{ Pattern = '(?m)^        config_bool_select\(leftPane, rightPane, getSettings\(\)\.game\.enableMapBackground,(?=\r?$)';
       Replacement = $uiNew.TrimEnd(); Expected = 1 }
)

if ($script:failed) { exit 1 }
exit 0
