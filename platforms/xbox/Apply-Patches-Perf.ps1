<#
.SYNOPSIS
  Performance on the Xbox (UWP): frame drops that depend on where the camera looks. Called by ci.ps1 before configure.

  REPORTED ON HARDWARE: in some areas the framerate falls a lot when looking in a certain direction.

  Prime suspects, all of which depend on the view and not on the area alone:
   * depth of field, mode "Dusk" (the default): drawDepth_blurTex() runs an 8-tap blur through 4 resolution
     levels (4 extra framebuffer copies, 8 TEV stages at half resolution) and then the DoF pass itself, whenever
     the stage's DoF parameters are active for the current view (m_Do_graphic.cpp, drawDepth2).
   * bloom, mode "Dusk" (the default): mDoGph_gInf_c::bloom_c::draw2() blurs the whole frame whenever the
     environment turns bloom on (sun glare, lighting that depends on the view direction).
   * the preset window's "Dusk" preset additionally sets shadow resolution x4 and the same two modes.
  These "Dusk" modes are quality upgrades made for desktop GPUs; an Xbox One S is far weaker.

  Edits (marker dusk_xbox_perf):
   1. src/dusk/settings.cpp   defaults on UWP: bloom Classic (the original effect), depth of field Off.
                              A value saved in the config file still wins, see 4.
   2. src/dusk/ui/preset.cpp  the "Dusk" preset on UWP no longer selects Dusk bloom / Dusk DoF / shadows x4.
   3. src/m_Do/m_Do_graphic.cpp  two counters (blur passes, bloom draws) for the diagnostic log.
   4. src/m_Do/m_Do_main.cpp  (a) once per install (marker file xbox-perf-profile-v1.txt in the log folder):
                                  settings saved with the heavy values (DoF Dusk, bloom Dusk, shadows > x1) are
                                  switched to the light ones, so the fix also reaches a config that already exists.
                                  Everything stays changeable in Settings > Graphics afterwards.
                              (b) perf-diag.log in the log folder: one line for every second in which the framerate
                                  was well below the best seen so far or a frame took over 100 ms, with stage, room,
                                  camera position and direction, draw call counts, pipelines still compiling and
                                  the DoF / bloom work done in that second. This shows which effect or which view
                                  is responsible if the drops remain.

  Idempotent. Exits 1 when an anchor does not match exactly once.
  Patched files must be listed in $alwaysFresh of Cache-Mtimes.ps1.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$script:failed = $false
$utf8 = New-Object System.Text.UTF8Encoding($false)
$marker = 'dusk_xbox_perf'

function Patch-Perf([string]$Rel, [object[]]$Edits) {
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

# --- 1. defaults -------------------------------------------------------------------------------
$bloomNew = @'
#ifdef DUSK_XBOX_UWP
        // dusk_xbox_perf: the Dusk bloom / depth of field are too heavy for the Xbox One S (Apply-Patches-Perf.ps1).
        .bloomMode {"game.bloomMode", BloomMode::Classic},
#else
        .bloomMode {"game.bloomMode", BloomMode::Dusk},
#endif
'@
$dofNew = @'
#ifdef DUSK_XBOX_UWP
        .depthOfFieldMode{"game.depthOfFieldMode", DepthOfFieldMode::Off},
#else
        .depthOfFieldMode{"game.depthOfFieldMode", DepthOfFieldMode::Dusk},
#endif
'@
Patch-Perf 'src/dusk/settings.cpp' @(
    @{ Pattern = '(?m)^        \.bloomMode \{"game\.bloomMode", BloomMode::Dusk\},(?=\r?$)';
       Replacement = $bloomNew.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^        \.depthOfFieldMode\{"game\.depthOfFieldMode", DepthOfFieldMode::Dusk\},(?=\r?$)';
       Replacement = $dofNew.TrimEnd(); Expected = 1 }
)

# --- 2. "Dusk" preset ----------------------------------------------------------------------------
$presetBloom = @'
#ifdef DUSK_XBOX_UWP
    // dusk_xbox_perf: no Dusk bloom / Dusk depth of field / 4x shadows on the Xbox One S.
    s.game.bloomMode.setValue(BloomMode::Classic);
#else
    s.game.bloomMode.setValue(BloomMode::Dusk);
#endif
'@
$presetDof = @'
#ifdef DUSK_XBOX_UWP
    s.game.depthOfFieldMode.setValue(DepthOfFieldMode::Off);
#else
    s.game.depthOfFieldMode.setValue(DepthOfFieldMode::Dusk);
#endif
'@
$presetShadow = @'
#ifdef DUSK_XBOX_UWP
    s.game.shadowResolutionMultiplier.setValue(1);
#else
    s.game.shadowResolutionMultiplier.setValue(4);
#endif
'@
Patch-Perf 'src/dusk/ui/preset.cpp' @(
    @{ Pattern = '(?m)^    s\.game\.bloomMode\.setValue\(BloomMode::Dusk\);(?=\r?$)';
       Replacement = $presetBloom.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^    s\.game\.depthOfFieldMode\.setValue\(DepthOfFieldMode::Dusk\);(?=\r?$)';
       Replacement = $presetDof.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^    s\.game\.shadowResolutionMultiplier\.setValue\(4\);(?=\r?$)';
       Replacement = $presetShadow.TrimEnd(); Expected = 1 }
)

# --- 3. counters in m_Do_graphic.cpp ----------------------------------------------------------------
$blurNew = @'
// dusk_xbox_perf: counters read by the performance log in m_Do_main.cpp.
int g_duskPerfDofBlur = 0;
int g_duskPerfBloom = 0;
static void drawDepth_blurTex(TGXTexObj &dst) {
    ++g_duskPerfDofBlur;
'@
$bloom2New = @'
    bool enabled = mEnable;
    if (mMonoColor.a == 0 && !enabled)
        return;
    ++g_duskPerfBloom;
'@
$bloom1New = @'
    bool enabled = mEnable && m_buffer != NULL;
    if (mMonoColor.a != 0 || enabled) {
        ++g_duskPerfBloom;
'@
Patch-Perf 'src/m_Do/m_Do_graphic.cpp' @(
    @{ Pattern = '(?m)^static void drawDepth_blurTex\(TGXTexObj &dst\) \{(?=\r?$)';
       Replacement = $blurNew.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^    bool enabled = mEnable;\r?\n    if \(mMonoColor\.a == 0 && !enabled\)\r?\n        return;';
       Replacement = $bloom2New.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^    bool enabled = mEnable && m_buffer != NULL;\r?\n    if \(mMonoColor\.a != 0 \|\| enabled\) \{';
       Replacement = $bloom1New.TrimEnd(); Expected = 1 }
)

# --- 4. m_Do_main.cpp: one-time profile + performance log ---------------------------------------------
$mainFuncs = @'
#include <aurora/aurora.h>

// dusk_xbox_perf: see platforms/xbox/Apply-Patches-Perf.ps1.
#include "d/d_camera.h"
#include "f_op/f_op_camera_mng.h"
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>

extern int g_duskPerfDofBlur;
extern int g_duskPerfBloom;

// Once per install: a config that already holds the heavy Dusk effects gets the light ones.
static void dusk_xbox_perf_profile() {
    std::error_code ec;
    const auto markerPath = dusk::CachePath / "xbox-perf-profile-v1.txt";
    if (std::filesystem::exists(markerPath, ec)) {
        return;
    }
    auto& game = dusk::getSettings().game;
    std::string changed;
    if (game.depthOfFieldMode.getValue() == dusk::DepthOfFieldMode::Dusk) {
        game.depthOfFieldMode.setValue(dusk::DepthOfFieldMode::Off);
        changed += "depth of field: Dusk -> Off\n";
    }
    if (game.bloomMode.getValue() == dusk::BloomMode::Dusk) {
        game.bloomMode.setValue(dusk::BloomMode::Classic);
        changed += "bloom: Dusk -> Classic\n";
    }
    if (game.shadowResolutionMultiplier.getValue() > 1) {
        game.shadowResolutionMultiplier.setValue(1);
        changed += "shadow resolution: -> x1\n";
    }
    if (!changed.empty()) {
        dusk::config::save();
    }
    std::ofstream out(markerPath, std::ios::trunc);
    if (out) {
        out << "Xbox performance profile v1 applied once (delete this file to apply it again).\n"
            << (changed.empty() ? "no setting had to be changed\n" : changed);
    }
}

// perf-diag.log: one line per second in which the framerate was well below the best seen so far,
// or a frame took over 100 ms.
static void dusk_xbox_perf_tick() {
    using clock = std::chrono::steady_clock;
    static const clock::time_point start = clock::now();
    static clock::time_point winStart = start;
    static clock::time_point last = start;
    static int frames = 0;
    static double worstMs = 0.0;
    static double peakFps = 0.0;
    static int linesWritten = 0;
    static int dofBase = 0;
    static int bloomBase = 0;
    static bool headerDone = false;

    const clock::time_point now = clock::now();
    const double ms = std::chrono::duration<double, std::milli>(now - last).count();
    last = now;
    ++frames;
    if (ms > worstMs) {
        worstMs = ms;
    }
    const double winMs = std::chrono::duration<double, std::milli>(now - winStart).count();
    if (winMs < 1000.0) {
        return;
    }

    const double fps = frames * 1000.0 / winMs;
    const int dof = g_duskPerfDofBlur - dofBase;
    const int bloom = g_duskPerfBloom - bloomBase;
    const double worst = worstMs;
    dofBase = g_duskPerfDofBlur;
    bloomBase = g_duskPerfBloom;
    frames = 0;
    worstMs = 0.0;
    winStart = now;
    if (fps > peakFps) {
        peakFps = fps;
    }

    if (linesWritten >= 4000 || !(fps < peakFps * 0.8 || worst > 100.0)) {
        return;
    }
    std::ofstream out(dusk::CachePath / "perf-diag.log", std::ios::app);
    if (!out) {
        return;
    }
    char line[512];
    if (!headerDone) {
        headerDone = true;
        const auto& game = dusk::getSettings().game;
        std::snprintf(line, sizeof(line),
            "# settings: bloom=%d dof=%d shadowMul=%d interp=%d resScale=%d noWaterRefraction=%d maxFps=%d "
            "(bloom/dof: 0 off, 1 classic, 2 dusk)\n",
            static_cast<int>(game.bloomMode.getValue()), static_cast<int>(game.depthOfFieldMode.getValue()),
            static_cast<int>(game.shadowResolutionMultiplier.getValue()),
            static_cast<int>(game.enableFrameInterpolation.getValue()),
            static_cast<int>(game.internalResolutionScale.getValue()),
            static_cast<int>(game.disableWaterRefraction.getValue()),
            static_cast<int>(dusk::getSettings().video.maxFrameRate.getValue()));
        out << line;
        out << "# t = seconds since start; dir = camera yaw/pitch in degrees; dofBlur/bloom = passes drawn in that second\n";
    }
    const double t = std::chrono::duration<double>(now - start).count();
    float ex = 0.0f, ey = 0.0f, ez = 0.0f, yaw = 0.0f, pitch = 0.0f;
    camera_process_class* cam = dComIfGp_getCamera(0);
    if (cam != nullptr) {
        const auto& eye = cam->view.lookat.eye;
        const auto& center = cam->view.lookat.center;
        ex = eye.x;
        ey = eye.y;
        ez = eye.z;
        const float dx = center.x - eye.x;
        const float dy = center.y - eye.y;
        const float dz = center.z - eye.z;
        yaw = std::atan2(dx, dz) * 57.29578f;
        pitch = std::atan2(dy, std::sqrt(dx * dx + dz * dz)) * 57.29578f;
    }
    const AuroraStats* stats = aurora_get_stats();
    std::snprintf(line, sizeof(line),
        "t=%.0f fps=%.1f worst=%.0fms stage=%s room=%d eye=(%.0f,%.0f,%.0f) dir=(%.0f,%.0f) draws=%u merged=%u "
        "pipesQueued=%u pipesCreated=%u uploadKB=%u dofBlur=%d bloom=%d\n",
        t, fps, worst, dComIfGp_getStartStageName(), static_cast<int>(dComIfGp_roomControl_getStayNo()), ex, ey, ez,
        yaw, pitch, stats->drawCallCount, stats->mergedDrawCallCount, stats->queuedPipelines,
        stats->createdPipelines, stats->lastTextureUploadSize / 1024u, dof, bloom);
    out << line;
    ++linesWritten;
}
'@
$mainCall = @'
    dusk::applyResampler(dusk::getSettings().game.resampler.getValue());
    dusk_xbox_perf_profile();
'@
$mainTick = @'
        aurora_end_frame();
        dusk_xbox_perf_tick();

        FrameMark;
'@
Patch-Perf 'src/m_Do/m_Do_main.cpp' @(
    @{ Pattern = '(?m)^#include <aurora/aurora\.h>(?=\r?$)';
       Replacement = $mainFuncs.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^    dusk::applyResampler\(dusk::getSettings\(\)\.game\.resampler\.getValue\(\)\);(?=\r?$)';
       Replacement = $mainCall.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^        aurora_end_frame\(\);\r?\n\r?\n        FrameMark;';
       Replacement = $mainTick.TrimEnd(); Expected = 1 }
)

if ($script:failed) { exit 1 }
exit 0
