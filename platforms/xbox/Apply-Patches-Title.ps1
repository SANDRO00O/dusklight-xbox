<#
.SYNOPSIS
  REMOVED: the Sacred Grove title scene (night shot, cinematic camera, camera editor, logo reveal).

  The Xbox build uses the stock title scene and animation again (Bridge of Eldin). This script is kept as an
  empty step only because Apply-Patches-Disc.ps1 calls it; it changes no source file.

  The files the old patch touched (src/d/d_com_inf_game.cpp, d_s_play.cpp, d_camera.cpp, d_stage.cpp,
  d_event.cpp and src/d/actor/d_a_title.cpp) must stay in $alwaysFresh of Cache-Mtimes.ps1: a cached build
  directory may still hold objects compiled from the patched text.
#>
param(
    [string]$RepoRoot = ''
)

Write-Host 'title scene: stock Bridge of Eldin scene and animation (the Sacred Grove override was removed)'
exit 0
