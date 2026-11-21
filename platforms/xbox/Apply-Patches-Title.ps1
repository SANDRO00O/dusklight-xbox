<#
.SYNOPSIS
  Title-screen scene: the Sacred Grove at night with a slow cinematic camera, the player hidden and a new
  logo reveal. Called by Apply-Patches-Disc.ps1. Patches src/d/d_com_inf_game.cpp, src/d/d_camera.cpp,
  src/d/d_stage.cpp, src/d/d_event.cpp and src/d/actor/d_a_title.cpp.

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
    * d_event.cpp: dEvt_control_c::entry() drops every event request while the title scene is up. Without it
      the Sacred Grove's own cutscene (Midna message cut) crashed the game 9 s after the title appeared,
      because the message object only exists in a real game (crash-diag: dMsgObject_c::endFlowGroupLocal).

  CAMERA EDITOR (in the game, on the title screen): press Y to enter / leave edit mode. Left stick moves,
  right stick looks, LT / RT go down / up, D-pad up / down change the field of view, hold A for fast, X resets
  to the default shot, B saves the pose to title-camera.txt (x y z yaw pitch fov) in the log folder and shows
  the numbers on screen (toast). A saved pose is loaded automatically at the next start and is then the base of
  the cinematic shot. The title logo is hidden and A / Start do not advance while editing. Delete
  title-camera.txt to return to the default shot.

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
bool g_duskTitleEdit = false;
bool g_duskTitleHavePose = false;
float g_duskTitlePose[6] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 52.0f};  // x y z yaw(deg) pitch(deg) fov(deg)
float g_duskTitleDef[6] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 52.0f};   // default shot, set by the camera hook

static void dusk_title_toast(const char* title, const std::string& text, int seconds) {
    dusk::ui::push_toast({
        .type = "info",
        .title = title,
        .content = text,
        .duration = std::chrono::seconds(seconds),
    });
}

static std::string dusk_title_pose_text() {
    char buf[200];
    std::snprintf(buf, sizeof(buf), "%.2f %.2f %.2f %.2f %.2f %.2f", (double)g_duskTitlePose[0],
                  (double)g_duskTitlePose[1], (double)g_duskTitlePose[2], (double)g_duskTitlePose[3],
                  (double)g_duskTitlePose[4], (double)g_duskTitlePose[5]);
    return buf;
}

static float dusk_title_dead(float v) {
    return (v > -0.12f && v < 0.12f) ? 0.0f : v;
}

// Title camera editor (Y toggles): left stick move, right stick look, LT/RT down/up, D-pad up/down field of
// view, hold A for fast, B saves title-camera.txt, X resets to the default shot. Called every tick by daTitle_c.
void dusk_title_edit_update() {
    if (!g_duskTitleActive) {
        g_duskTitleEdit = false;
        return;
    }
    if (mDoCPd_c::getTrigY(PAD_1) && g_duskTitleAnchorSet) {
        g_duskTitleEdit = !g_duskTitleEdit;
        if (g_duskTitleEdit) {
            if (!g_duskTitleHavePose) {
                std::memcpy(g_duskTitlePose, g_duskTitleDef, sizeof(g_duskTitlePose));
                g_duskTitleHavePose = true;
            }
            dusk_title_toast("Title camera: edit mode",
                "Left stick: move | Right stick: look | LT / RT: down / up | D-pad up / down: field of "
                "view | hold A: fast | B: save | X: reset | Y: exit",
                9);
        } else {
            dusk_title_toast("Title camera", "Edit mode off. The new view plays as the title shot (not saved until you pressed B).", 5);
        }
        return;
    }
    if (!g_duskTitleEdit) {
        return;
    }
    float* P = g_duskTitlePose;
    const float kDeg = 3.14159265f / 180.0f;
    const float fast = mDoCPd_c::getHoldA(PAD_1) ? 4.0f : 1.0f;
    const float sx = dusk_title_dead(mDoCPd_c::getStickX(PAD_1));
    const float sy = dusk_title_dead(mDoCPd_c::getStickY(PAD_1));
    const float cx = dusk_title_dead(mDoCPd_c::getSubStickX(PAD_1));
    const float cy = dusk_title_dead(mDoCPd_c::getSubStickY(PAD_1));
    const float lift = mDoCPd_c::getAnalogR(PAD_1) - mDoCPd_c::getAnalogL(PAD_1);
    const float speed = 6.0f * fast;

    P[3] += cx * 2.0f * fast * 0.5f;
    P[4] += cy * 1.5f * fast * 0.5f;
    if (P[4] > 85.0f) {
        P[4] = 85.0f;
    }
    if (P[4] < -85.0f) {
        P[4] = -85.0f;
    }
    if (P[3] >= 360.0f) {
        P[3] -= 360.0f;
    }
    if (P[3] < 0.0f) {
        P[3] += 360.0f;
    }
    const float yaw = P[3] * kDeg;
    const float pitch = P[4] * kDeg;
    const float fx = sinf(yaw) * cosf(pitch);
    const float fy = sinf(pitch);
    const float fz = cosf(yaw) * cosf(pitch);
    P[0] += (fx * sy + cosf(yaw) * sx) * speed;
    P[1] += (fy * sy + lift) * speed;
    P[2] += (fz * sy - sinf(yaw) * sx) * speed;
    if (mDoCPd_c::getHoldUp(PAD_1)) {
        P[5] += 0.4f * fast;
    }
    if (mDoCPd_c::getHoldDown(PAD_1)) {
        P[5] -= 0.4f * fast;
    }
    if (P[5] < 15.0f) {
        P[5] = 15.0f;
    }
    if (P[5] > 100.0f) {
        P[5] = 100.0f;
    }

    if (mDoCPd_c::getTrigX(PAD_1)) {
        std::memcpy(g_duskTitlePose, g_duskTitleDef, sizeof(g_duskTitlePose));
        dusk_title_toast("Title camera", "Reset to the default shot", 2);
    }
    if (mDoCPd_c::getTrigB(PAD_1)) {
        const std::string line = dusk_title_pose_text();
        std::ofstream out(dusk::CachePath / "title-camera.txt", std::ios::trunc);
        if (out) {
            out << line << "\n";
        }
        out.close();
        OSReport("title camera saved: x y z yaw pitch fov = %s\n", line.c_str());
        dusk_title_toast(out ? "Title camera saved" : "Title camera: could not write the file",
                         "x y z yaw pitch fov = " + line + "  (file title-camera.txt)", 12);
    }
}

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
    g_duskTitleEdit = false;
    g_duskTitleHavePose = false;
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
    if (g_duskTitleActive) {
        // a camera pose saved from the editor (B in edit mode): x y z yaw pitch fov
        std::ifstream cam(dusk::CachePath / "title-camera.txt");
        float v[6];
        if (cam && (cam >> v[0] >> v[1] >> v[2] >> v[3] >> v[4] >> v[5]) && v[5] > 5.0f && v[5] < 120.0f) {
            std::memcpy(g_duskTitlePose, v, sizeof(v));
            g_duskTitleHavePose = true;
            OSReport("title camera: loaded title-camera.txt\n");
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
extern bool g_duskTitleEdit;
void dusk_title_edit_update();
static int g_duskTitleWaitFrames = 0;
'@

$externCamera = @'
$1
extern bool g_duskTitleActive;   // dusk_xbox_title
extern int g_duskTitleTick;
extern bool g_duskTitleAnchorSet;
extern float g_duskTitleCam[4];
extern bool g_duskTitleEdit;
extern bool g_duskTitleHavePose;
extern float g_duskTitlePose[6];
extern float g_duskTitleDef[6];
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

            const float kDeg = 3.14159265f / 180.0f;
            const float ang = (float)s_titleAngle * (3.14159265f / 32768.0f);
            // default shot: behind the spawn point, looking the way the player faces
            g_duskTitleDef[0] = s_titleAnchor.x - sinf(ang) * g_duskTitleCam[0];
            g_duskTitleDef[1] = s_titleAnchor.y + g_duskTitleCam[1];
            g_duskTitleDef[2] = s_titleAnchor.z - cosf(ang) * g_duskTitleCam[0];
            g_duskTitleDef[3] = ang / kDeg;
            g_duskTitleDef[4] = 1.3f;
            g_duskTitleDef[5] = g_duskTitleCam[3];
            const float* pose = g_duskTitleHavePose ? g_duskTitlePose : g_duskTitleDef;

            const float t = (float)g_duskTitleTick;
            float k = t / 600.0f;
            if (k > 1.0f) {
                k = 1.0f;
            }
            const float ease = k * k * (3.0f - 2.0f * k);
            const float yaw = pose[3] * kDeg;
            const float pitch = pose[4] * kDeg;
            const float fx = sinf(yaw);
            const float fz = cosf(yaw);
            float sway = 0.0f;
            float push = 0.0f;
            float rise = 0.0f;
            float pan = 0.0f;
            float fov = pose[5];
            if (!g_duskTitleEdit) {
                sway = sinf(t * 0.0105f) * 45.0f;
                push = ease * g_duskTitleCam[2];
                rise = ease * 35.0f;
                pan = sinf(t * 0.0105f + 1.0f) * 0.15f;
                fov = pose[5] - 6.0f * ease;
            }
            cXyz titleEye(pose[0] + fx * push + fz * sway, pose[1] + rise, pose[2] + fz * push - fx * sway);
            const float lookYaw = yaw + pan;
            const float cp = cosf(pitch);
            cXyz titleCenter(titleEye.x + sinf(lookYaw) * cp * 900.0f, titleEye.y + sinf(pitch) * 900.0f,
                             titleEye.z + cosf(lookYaw) * cp * 900.0f);
            Reset(titleCenter, titleEye, fov, 0);
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

$eventGate = @'
int dEvt_control_c::entry() {
    // dusk_xbox_title: no events (stage cutscenes, message tags) while the title scene is up. The Sacred Grove
    // starts a Midna cutscene whose message cut needs the message object, which only exists in a real game:
    // crash at dMsgObject_c::endFlowGroupLocal (null this). The requests are dropped like entry() drops them.
    {
        extern bool g_duskTitleActive;
        if (g_duskTitleActive) {
            mNum = 0;
            return 0;
        }
    }
    if (mNum != 0) {
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
    // dusk_xbox_title: camera editor (Y) and the time of day pinned to night while the title screen is up
    if (g_duskTitleActive) {
        dusk_title_edit_update();
        if (g_duskTitleHour >= 0.0f) {
            dComIfGs_setTime(g_duskTitleHour * 15.0f);
        }
    }
    (this->*daTitleProc[mProcID])();
'@

$keyWaitGate = @'
    if (!g_duskTitleEdit && (mDoCPd_c::getTrigA(PAD_1) || mDoCPd_c::getTrigStart(PAD_1))) {
        mDoAud_seStart(Z2SE_TITLE_ENTER, NULL, 0, 0);
'@

$drawGate = @'
    if (mIsDispLogo && !g_duskTitleEdit) {
        dComIfGd_set2DOpaTop(&mTitle);
'@

$waitFallback = @'
    if (!g_duskTitleEdit && (mDoCPd_c::getTrigA(PAD_1) || mDoCPd_c::getTrigStart(PAD_1))) {
        fastLogoDispInit();
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
            @{ Pattern = '(?m)^#include <cstring>(?=\r?$)'; Replacement = "#include <cstring>`n#include <cmath>`n#include <chrono>`n#include <fstream>`n#include <string>`n#include `"dusk/main.h`"`n#include `"dusk/ui/ui.hpp`""; Expected = 1 },
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
        Rel = 'src/d/d_event.cpp'
        Edits = @(
            @{ Pattern = '(?m)^int dEvt_control_c::entry\(\) \{\r?\n    if \(mNum != 0\) \{(?=\r?$)'; Replacement = $eventGate.TrimEnd(); Expected = 1 }
        )
    },
    @{
        Rel = 'src/d/actor/d_a_title.cpp'
        Edits = @(
            @{ Pattern = '(?m)^(#include "m_Do/m_Do_graphic\.h")(?=\r?$)'; Replacement = $externTitle.TrimEnd(); Expected = 1 },
            @{ Pattern = '(?m)^void daTitle_c::logoDispWaitInit\(\) \{\r?\n    mProcID = 1;\r?\n\}'; Replacement = $waitInit.TrimEnd(); Expected = 1 },
            @{ Pattern = '(?m)^    if \(mDoCPd_c::getTrigA\(PAD_1\) \|\| mDoCPd_c::getTrigStart\(PAD_1\)\) \{\r?\n        fastLogoDispInit\(\);\r?\n    \} else if \(getDemoPrm\(\) == 1\) \{\r?\n        logoDispAnmInit\(\);\r?\n    \}'; Replacement = $waitFallback.TrimEnd(); Expected = 1 },
            @{ Pattern = '(?m)^    if \(mDoCPd_c::getTrigA\(PAD_1\) \|\| mDoCPd_c::getTrigStart\(PAD_1\)\) \{\r?\n        mDoAud_seStart\(Z2SE_TITLE_ENTER, NULL, 0, 0\);'; Replacement = $keyWaitGate.TrimEnd(); Expected = 1 },
            @{ Pattern = '(?m)^    if \(mIsDispLogo\) \{\r?\n        dComIfGd_set2DOpaTop\(&mTitle\);'; Replacement = $drawGate.TrimEnd(); Expected = 1 },
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
