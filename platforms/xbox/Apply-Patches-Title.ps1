<#
.SYNOPSIS
  Title-screen scene: the Sacred Grove at night with a slow cinematic camera, the player hidden and a new
  logo reveal. Called by Apply-Patches-Disc.ps1. Patches src/d/d_com_inf_game.cpp, src/d/d_camera.cpp,
  src/d/d_stage.cpp and src/d/actor/d_a_title.cpp.

  WHAT the player sees after the disc is loaded (instead of the Bridge of Eldin demo):
    * the Sacred Grove (stage F_SP117, room 1, spawn point 100) at midnight (the time of day is pinned
      while the title screen is up),
    * a slow cinematic camera: it starts a little behind the spawn point, pushes in over ~20 s with a gentle
      sideways sway and a small rise, the look-at point drifts slowly and the field of view narrows a bit.
      It never stops moving while the title screen is up,
    * Link is not drawn and does not run (so he cannot be moved or make sounds),
    * the logo reveal starts after 5 s (150 ticks) of that camera shot (A / Start still skip ahead), then
      the stock logo animation and "Press Start" follow. Pressing A / Start continues to the file select.

  HOW:
    * dComIfG_changeOpeningScene requests the stage above instead of F_SP102 (dusk_title_next_stage).
    * dCamera_c::Run (d_camera.cpp), only while the title actor exists, replaces the normal camera by the
      shot above, computed from where the (hidden) player stands and which way he faces, and marks the
      player no-execute + no-draw (fopAcStts_NOEXEC_e | fopAcStts_UNK_0x20000000_e, the latter is not
      cleared by the draw loop, so interpolated frames cannot show him).
    * daTitle_c (d_a_title.cpp): pins the time of day, resets the shot, shows the logo after the 150-tick
      intro when no stb demo drives it, and switches everything off again when the title actor is deleted.
    * d_stage.cpp: if the spawn point is not found in the chosen layer, the title falls back to the first
      spawn point of the stage instead of the fatal "Failed to find player start point" (which would abort).

  OPTIONAL TUNING, no rebuild needed: a text file title-scene.txt in the log folder (CachePath):
      STAGE POINT ROOM LAYER HOUR [BACK UP DRIFT FOV]
      default (what is used without the file):  F_SP117 100 1 -1 0 60 170 140 52
        BACK  = how far behind the spawn point the camera starts (game units)
        UP    = camera height above the spawn point
        DRIFT = how far the push-in travels forward
        FOV   = starting field of view in degrees (ends 6 degrees narrower)
      The single word "off" restores the stock Bridge of Eldin title scene. A wrong STAGE / ROOM can still
      fail to load: delete the file to go back to the default.

  Not run on hardware when this was written. Idempotent (marker dusk_xbox_title). Exits 1 when an anchor does
  not match exactly once. The patched files are listed in $alwaysFresh of Cache-Mtimes.ps1.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$marker = 'dusk_xbox_title'

# ---------------- replacement texts ----------------
$gameFunc = @'
// dusk_xbox_title: Sacred Grove at night as the title scene, see platforms/xbox/Apply-Patches-Title.ps1
bool g_duskTitleActive = false;
float g_duskTitleHour = -1.0f;
int g_duskTitleTick = 0;
bool g_duskTitleAnchorSet = false;
float g_duskTitleCam[4] = {60.0f, 170.0f, 140.0f, 52.0f};

static void dusk_title_next_stage() {
    static char stage[16];
    int point = 100;
    int room = 1;
    int layer = -1;
    float hour = 0.0f;
    std::strcpy(stage, "F_SP117");
    g_duskTitleActive = true;
    g_duskTitleTick = 0;
    g_duskTitleAnchorSet = false;
    g_duskTitleCam[0] = 60.0f;
    g_duskTitleCam[1] = 170.0f;
    g_duskTitleCam[2] = 140.0f;
    g_duskTitleCam[3] = 52.0f;

    std::ifstream in(dusk::CachePath / "title-scene.txt");
    if (in) {
        std::string name;
        in >> name;
        if (name == "off") {
            std::strcpy(stage, "F_SP102");
            point = 100;
            room = 0;
            layer = 10;
            hour = -1.0f;
            g_duskTitleActive = false;
        } else {
            int p = 0, r = 0, l = 0;
            float h = 0.0f;
            if (!name.empty() && name.size() <= 7 && (in >> p >> r >> l >> h) && p >= 0 &&
                p <= 255 && r >= -1 && r <= 63 && l >= -1 && l <= 14)
            {
                std::strcpy(stage, name.c_str());
                point = p;
                room = r;
                layer = l;
                hour = (h >= 0.0f && h < 24.0f) ? h : -1.0f;
                float v = 0.0f;
                for (int i = 0; i < 4 && (in >> v); i++) {
                    g_duskTitleCam[i] = v;
                }
            } else {
                OSReport("title scene: title-scene.txt is not 'STAGE POINT ROOM LAYER HOUR [BACK UP DRIFT FOV]', using the default\n");
            }
        }
    }
    g_duskTitleHour = hour;
    OSReport("title scene: %s point %d room %d layer %d hour %.1f cam %.0f/%.0f/%.0f/%.0f%s\n", stage,
             point, room, layer, (double)hour, (double)g_duskTitleCam[0], (double)g_duskTitleCam[1],
             (double)g_duskTitleCam[2], (double)g_duskTitleCam[3],
             g_duskTitleActive ? "" : " (stock scene)");
    dComIfGp_setNextStage(stage, (s16)point, (s8)room, (s8)layer);
}

int dComIfG_changeOpeningScene(scene_class* i_scene, s16 i_procName) {
'@

$externTitle = @'
$1
extern bool g_duskTitleActive;   // dusk_xbox_title
extern float g_duskTitleHour;
extern int g_duskTitleTick;
extern bool g_duskTitleAnchorSet;
static int g_duskTitleWaitFrames = 0;
'@

$externCamera = @'
$1
extern bool g_duskTitleActive;   // dusk_xbox_title
extern int g_duskTitleTick;
extern bool g_duskTitleAnchorSet;
extern float g_duskTitleCam[4];
'@

$externStage = @'
$1
extern bool g_duskTitleActive;   // dusk_xbox_title
'@

$cameraHook = @'
    // dusk_xbox_title: cinematic title camera, only while the title actor exists. See Apply-Patches-Title.ps1.
    if (g_duskTitleActive && fopAcM_SearchByName(fpcNm_TITLE_e) != NULL) {
        daAlink_c* titleLink = daAlink_getAlinkActorClass();
        if (titleLink != NULL) {
            static cXyz s_titleAnchor;
            static s16 s_titleAngle;
            if (!g_duskTitleAnchorSet) {
                s_titleAnchor = titleLink->current.pos;
                s_titleAngle = titleLink->shape_angle.y;
                g_duskTitleAnchorSet = true;
            }
            // hidden and idle: no input, no sounds, nothing drawn (this bit is not cleared by the draw loop)
            fopAcM_OnStatus(titleLink, fopAcStts_NOEXEC_e | fopAcStts_UNK_0x20000000_e);

            const float t = (float)g_duskTitleTick;
            float k = t / 600.0f;
            if (k > 1.0f) {
                k = 1.0f;
            }
            const float ease = k * k * (3.0f - 2.0f * k);
            const float ang = (float)s_titleAngle * (3.14159265f / 32768.0f);
            const float fx = sinf(ang);
            const float fz = cosf(ang);
            const float rx = fz;
            const float rz = -fx;
            const float sway = sinf(t * 0.0105f) * 45.0f;
            const float push = ease * g_duskTitleCam[2] - g_duskTitleCam[0];
            cXyz titleEye(s_titleAnchor.x + fx * push + rx * sway,
                          s_titleAnchor.y + g_duskTitleCam[1] + ease * 35.0f,
                          s_titleAnchor.z + fz * push + rz * sway);
            const float pan = sinf(t * 0.0105f + 1.0f) * 140.0f;
            cXyz titleCenter(s_titleAnchor.x + fx * 900.0f + rx * pan,
                             s_titleAnchor.y + g_duskTitleCam[1] + 20.0f + ease * 10.0f,
                             s_titleAnchor.z + fz * 900.0f + rz * pan);
            Reset(titleCenter, titleEye, g_duskTitleCam[3] - 6.0f * ease, 0);
            g_duskTitleTick++;
        }
        mFrameCounter++;
        mTicks++;
        return true;
    }
    if (executeDebugFlyCam() || dusk::mods::camera_run_operators(this)) {
'@

$stageFallback = @'
            } else if (g_duskTitleActive && num > 0) {
                // dusk_xbox_title: the title scene must never abort, use the first spawn point
                player_data = player->m_entries;
                OSReport("title scene: spawn point %d not found, using the first one\n", (int)point);
            } else {
                // If the requested spawn point isn't found, print all valid points within the log
'@

$waitInit = @'
void daTitle_c::logoDispWaitInit() {
    g_duskTitleWaitFrames = 0;   // dusk_xbox_title
    g_duskTitleTick = 0;
    g_duskTitleAnchorSet = false;
    mProcID = 1;
}
'@

$deleteHead = @'
int daTitle_c::Delete() {
    g_duskTitleActive = false;   // dusk_xbox_title: the title scene is over (camera, time pin, spawn fallback)
'@

$exec = @'
    // dusk_xbox_title: pin the time of day (night) while the title screen is up
    if (g_duskTitleActive && g_duskTitleHour >= 0.0f) {
        dComIfGs_setTime(g_duskTitleHour * 15.0f);
    }
    (this->*daTitleProc[mProcID])();
'@

$waitFallback = @'
    } else if (getDemoPrm() == 1) {
        logoDispAnmInit();
    } else if (g_duskTitleActive && ++g_duskTitleWaitFrames > 150) {
        // dusk_xbox_title: no stb demo in this stage; the logo is revealed after 5 s of the cinematic shot
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
        Rel = 'src/d/d_camera.cpp'
        Edits = @(
            @{ Pattern = '(?m)^(#include <cmath>)(?=\r?$)'; Replacement = $externCamera.TrimEnd(); Expected = 1 },
            @{ Pattern = '(?m)^    if \(executeDebugFlyCam\(\) \|\| dusk::mods::camera_run_operators\(this\)\) \{(?=\r?$)'; Replacement = $cameraHook.TrimEnd(); Expected = 1 }
        )
    },
    @{
        Rel = 'src/d/d_stage.cpp'
        Edits = @(
            @{ Pattern = '(?m)^(#include "m_Do/m_Do_Reset\.h")(?=\r?$)'; Replacement = $externStage.TrimEnd(); Expected = 1 },
            @{ Pattern = '(?m)^            \} else \{\r?\n                // If the requested spawn point isn''t found, print all valid points within the log[ \t]*(?=\r?$)'; Replacement = $stageFallback.TrimEnd(); Expected = 1 }
        )
    },
    @{
        Rel = 'src/d/actor/d_a_title.cpp'
        Edits = @(
            @{ Pattern = '(?m)^(#include "m_Do/m_Do_graphic\.h")(?=\r?$)'; Replacement = $externTitle.TrimEnd(); Expected = 1 },
            @{ Pattern = '(?m)^void daTitle_c::logoDispWaitInit\(\) \{\r?\n    mProcID = 1;\r?\n\}'; Replacement = $waitInit.TrimEnd(); Expected = 1 },
            @{ Pattern = '(?m)^    \} else if \(getDemoPrm\(\) == 1\) \{\r?\n        logoDispAnmInit\(\);\r?\n    \}'; Replacement = $waitFallback.TrimEnd(); Expected = 1 },
            @{ Pattern = '(?m)^    \(this->\*daTitleProc\[mProcID\]\)\(\);(?=\r?$)'; Replacement = $exec.TrimEnd(); Expected = 1 },
            @{ Pattern = '(?m)^int daTitle_c::Delete\(\) \{(?=\r?$)'; Replacement = $deleteHead.TrimEnd(); Expected = 1 }
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
    Write-Host "patched: $($w.Rel) ($($w.Edits.Count) edit(s): Sacred Grove night title scene)"
}
exit 0
