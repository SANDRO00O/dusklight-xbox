<#
.SYNOPSIS
  Cheaper UI styling on the Xbox (UWP). Called by Apply-Patches-Disc.ps1 from ci.ps1 before configure.

  FOUND ON HARDWARE: the framerate drops while the mods page (and other windows) are open. RmlUi draws
  `backdrop-filter: blur(...)` and blurred `box-shadow`s through extra render passes (the backdrop blur
  re-blurs the whole screen behind the window every frame, a shadow with a blur radius needs its own
  offscreen pass per element, and the mod catalog shows many cards), which is expensive on the Xbox One
  S GPU. This patch removes the blur effects from the stylesheets in res/rml for this build only:

    * every `backdrop-filter: blur(...)` in res/rml/*.rcss
    * the blurred shadow of windows (window.rcss), popovers (popover.rcss) and the mod icons in
      mod_browser.rcss

  The windows lose their frosted-glass look; the background colour is already 90% opaque, so they stay
  readable.

  Also (reported: scrolling the mods list is very slow, the fps overlay reads 3; cause not measured yet, these are
  the likely suspects):
    * mods.rcss: the animated gradient `transition` on the mod rows is removed
    * mod_browser.rcss: catalog cards lose `overflow: hidden` + the 12dp radius (a rounded clip makes RmlUi write
      a stencil clip mask per card and per frame); the cards get a 4dp radius and no clipping

  NOT measured on hardware yet. Best effort: a stylesheet that changed upstream only prints a
  warning and keeps its effects, the build never fails because of this script.

  Idempotent (a removed blur no longer matches). res/ files are packaged by xbox-project.cmake.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$dir = Join-Path $RepoRoot 'res/rml'
if (-not (Test-Path $dir)) {
    Write-Host "::warning::res/rml not found, UI blur effects left as they are"
    exit 0
}

$note = '/* dusk_xbox_ui: removed, too expensive on the Xbox One S (see Apply-Patches-Ui.ps1) */'
$edits = @(
    # file (relative to res/rml), regex (whole declaration line), replacement
    @{ File = '*';                Rx = '(?m)^(\s*)backdrop-filter: blur\([^)]*\);(?=\r?$)';                                         To = '$1' + $note },
    @{ File = 'window.rcss';      Rx = '(?m)^(\s*)box-shadow: 0 0 25dp 5dp;(?=\r?$)';                                               To = '$1box-shadow: none; ' + $note },
    @{ File = 'popover.rcss';     Rx = '(?m)^(\s*)box-shadow: 0 6dp 24dp 2dp rgba\(var\(--color-black-rgb\), 55%\);(?=\r?$)';        To = '$1box-shadow: none; ' + $note },
    @{ File = 'mod_browser.rcss'; Rx = '(?m)^(\s*)box-shadow: rgba\(var\(--color-black-rgb\), (?:60|65)%\) 0 (?:6|8)dp (?:16|20)dp;(?=\r?$)'; To = '$1box-shadow: none; ' + $note },
    # Mods list: no animated gradient on the rows (every focus / hover change re-animates the decorator).
    @{ File = 'mods.rcss';        Rx = '(?m)^(\s*)transition: decorator 0\.1s linear-in-out;(?=\r?$)';                                To = '$1transition: none; ' + $note },
    # Mod catalog cards: `overflow: hidden` together with `border-radius` makes RmlUi write a stencil clip mask
    # (two full-window quads) for every card on every frame. Square-ish corners and no clipping instead.
    @{ File = 'mod_browser.rcss'; Rx = '(?m)^(\s*)overflow: hidden;(\r?\n\s*text-align: left;\r?\n\s*)border-radius: 12dp;(?=\r?$)'; To = '${1}overflow: visible;${2}border-radius: 4dp; ' + $note }
)

$total = 0
foreach ($file in (Get-ChildItem -Path $dir -File -Filter '*.rcss')) {
    $text = [System.IO.File]::ReadAllText($file.FullName)
    $changed = 0
    foreach ($e in $edits) {
        if ($e.File -ne '*' -and $e.File -ne $file.Name) { continue }
        $n = [regex]::Matches($text, $e.Rx).Count
        if ($n -gt 0) {
            $text = [regex]::Replace($text, $e.Rx, $e.To)
            $changed += $n
        }
    }
    if ($changed -gt 0) {
        [System.IO.File]::WriteAllText($file.FullName, $text, $utf8)
        Write-Host "patched: res/rml/$($file.Name) ($changed blur effect(s) removed)"
        $total += $changed
    }
}
if ($total -eq 0) { Write-Host "::warning::no blur effects found in res/rml (already patched, or upstream changed?)" }
else { Write-Host "UI blur effects removed: $total" }
exit 0
