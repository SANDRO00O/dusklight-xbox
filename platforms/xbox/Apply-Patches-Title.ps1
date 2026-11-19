<#
.SYNOPSIS
  Optional title-screen scene override (EXPERIMENTAL). Called by Apply-Patches-Disc.ps1. Patches
  src/d/d_com_inf_game.cpp, src/d/d_s_play.cpp and src/d/actor/d_a_title.cpp.

  WHAT: the scene behind the "Press Start" logo after the disc is loaded is the real game stage F_SP102
  (Bridge of Eldin, layer 10), played by a demo that also drives its camera. This patch lets the user pick
  another stage / point / room / layer / hour WITHOUT rebuilding, through a text file in the folder that
  holds the logs (CachePath):

      title-scene.txt   ->   one line:  STAGE POINT ROOM LAYER HOUR
      example (Sacred Grove, night):    F_SP117 100 1 -1 0

  Without the file nothing changes (stock Bridge of Eldin scene). Delete the file to go back.

  HOW:
    * dComIfG_changeOpeningScene reads the file and requests that stage instead of F_SP102 (a bad / missing
      file keeps the stock request). The result is logged: "title scene: ...".
    * d_s_play, right after dComIfGs_init() of the opening scene, sets the time of day to HOUR (the stage's
      own time override, if it has one, still wins).
    * The logo normally appears when the stb demo of F_SP102 sends a parameter; other stages have no such
      demo, so the title actor falls back to showing the logo after 90 frames (A / Start still skips ahead).

  KNOWN RISKS (not run, only read from the source): the camera was driven by the demo in F_SP102, so another
  stage shows its normal gameplay camera; Link exists in the scene and can be moved with the stick until the
  user presses A / Start; the stage's own spawn events could trigger. If the title screen misbehaves, delete
  title-scene.txt (no rebuild needed) or try another POINT / LAYER.

  Idempotent (marker dusk_xbox_title). Exits 1 when an anchor does not match exactly once. The three patched
  files are listed in $alwaysFresh of Cache-Mtimes.ps1.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$marker = 'dusk_xbox_title'

# ---------------- replacement texts ----------------
$gameFunc = @'
// dusk_xbox_title: optional title-scene override, see platforms/xbox/Apply-Patches-Title.ps1
bool g_duskTitleActive = false;
float g_duskTitleHour = -1.0f;

static void dusk_title_next_stage() {
    static char stage[16];
    int point = 100;
    int room = 0;
    int layer = 10;
    g_duskTitleActive = false;
    g_duskTitleHour = -1.0f;
    std::strcpy(stage, "F_SP102");

    std::ifstream in(dusk::CachePath / "title-scene.txt");
    if (in) {
        std::string name;
        int p = 0, r = 0, l = 0;
        float h = -1.0f;
        if ((in >> name >> p >> r >> l >> h) && !name.empty() && name.size() <= 7 &&
            p >= 0 && p <= 255 && r >= -1 && r <= 63 && l >= -1 && l <= 14)
        {
            std::strcpy(stage, name.c_str());
            point = p;
            room = r;
            layer = l;
            g_duskTitleActive = true;
            if (h >= 0.0f && h < 24.0f) {
                g_duskTitleHour = h;
            }
        } else {
            OSReport("title scene: title-scene.txt is not 'STAGE POINT ROOM LAYER HOUR', ignored\n");
        }
    }
    OSReport("title scene: %s point %d room %d layer %d hour %.1f%s\n", stage, point, room, layer,
             (double)g_duskTitleHour, g_duskTitleActive ? " (override)" : " (stock)");
    dComIfGp_setNextStage(stage, (s16)point, (s8)room, (s8)layer);
}

int dComIfG_changeOpeningScene(scene_class* i_scene, s16 i_procName) {
'@

$externPlay = @'
$1
extern bool g_duskTitleActive;   // dusk_xbox_title
extern float g_duskTitleHour;
'@

$externTitle = @'
$1
extern bool g_duskTitleActive;   // dusk_xbox_title
static int g_duskTitleWaitFrames = 0;
'@

$waitInit = @'
void daTitle_c::logoDispWaitInit() {
    g_duskTitleWaitFrames = 0;   // dusk_xbox_title
    mProcID = 1;
}
'@

$waitFallback = @'
    } else if (getDemoPrm() == 1) {
        logoDispAnmInit();
    } else if (g_duskTitleActive && ++g_duskTitleWaitFrames > 90) {
        // dusk_xbox_title: no stb demo in this stage, show the logo after 90 frames
        logoDispAnmInit();
    }
'@

# ---------------- targets ----------------
$targets = @(
    @{
        Rel = 'src/d/d_com_inf_game.cpp'
        Edits = @(
            @{ Pattern = '(?m)^#include <cstring>(?=\r?$)'; Replacement = "#include <cstring>`n#include <fstream>`n#include <string>`n#include `"dusk/main.h`""; Expected = 1 },
            @{ Pattern = '(?m)^int dComIfG_changeOpeningScene\(scene_class\* i_scene, s16 i_procName\) \{(?=\r?$)'; Replacement = $gameFunc.TrimEnd(); Expected = 1 },
            @{ Pattern = '(?m)^    dComIfGp_setNextStage\("F_SP102", 100, 0, 10\);(?=\r?$)'; Replacement = '    dusk_title_next_stage();'; Expected = 1 }
        )
    },
    @{
        Rel = 'src/d/d_s_play.cpp'
        Edits = @(
            @{ Pattern = '(?m)^(#include "m_Do/m_Do_graphic\.h")(?=\r?$)'; Replacement = $externPlay.TrimEnd(); Expected = 1 },
            @{ Pattern = '(?m)^([ \t]+)(dComIfGs_onEventBit\(0x0601\);[^\r\n]*)(?=\r?$)'; Replacement = '$1$2' + "`n" + '$1// dusk_xbox_title' + "`n" + '$1if (g_duskTitleHour >= 0.0f) {' + "`n" + '$1    dComIfGs_setTime(g_duskTitleHour * 15.0f);' + "`n" + '$1}'; Expected = 1 }
        )
    },
    @{
        Rel = 'src/d/actor/d_a_title.cpp'
        Edits = @(
            @{ Pattern = '(?m)^(#include "m_Do/m_Do_graphic\.h")(?=\r?$)'; Replacement = $externTitle.TrimEnd(); Expected = 1 },
            @{ Pattern = '(?m)^void daTitle_c::logoDispWaitInit\(\) \{\r?\n    mProcID = 1;\r?\n\}'; Replacement = $waitInit.TrimEnd(); Expected = 1 },
            @{ Pattern = '(?m)^    \} else if \(getDemoPrm\(\) == 1\) \{\r?\n        logoDispAnmInit\(\);\r?\n    \}'; Replacement = $waitFallback.TrimEnd(); Expected = 1 }
        )
    }
)

# ---------------- read + check everything first, write only when all anchors match ----------------
$work = @()
foreach ($t in $targets) {
    $path = Join-Path $RepoRoot $t.Rel
    if (-not (Test-Path $path)) {
        Write-Host "::error::patch target missing: $($t.Rel)"
        exit 1
    }
    $text = [System.IO.File]::ReadAllText($path)
    if ($text.Contains($marker)) {
        Write-Host "already patched: $($t.Rel)"
        continue
    }
    foreach ($e in $t.Edits) {
        $count = [regex]::Matches($text, $e.Pattern).Count
        if ($count -ne $e.Expected) {
            Write-Host "::error::patch anchor '$($e.Pattern)' in $($t.Rel) matched $count time(s), expected $($e.Expected) (upstream changed?)"
            exit 1
        }
    }
    $work += @{ Path = $path; Rel = $t.Rel; Text = $text; Edits = $t.Edits }
}
foreach ($w in $work) {
    $text = $w.Text
    foreach ($e in $w.Edits) {
        $text = [regex]::Replace($text, $e.Pattern, $e.Replacement)
    }
    [System.IO.File]::WriteAllText($w.Path, $text, $utf8)
    Write-Host "patched: $($w.Rel) ($($w.Edits.Count) edit(s): optional title-scene override)"
}
exit 0
