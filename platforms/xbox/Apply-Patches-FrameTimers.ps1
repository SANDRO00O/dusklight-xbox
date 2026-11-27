<#
.SYNOPSIS
  Frame stage timers for aurora::end_frame (extern/aurora/lib/aurora.cpp). Called by Apply-Patches-Disc.ps1.

  FOUND ON HARDWARE (perf-diag.log): with the mods list open endMs (the time the main thread spends in
  aurora_end_frame) rises to ~340 ms at ~300 draw calls, while ui::update() is cheap. aurora_end_frame does, on the
  main thread: GX fifo drain + gfx::finish, ImGui freeze, RmlUi record_frame, and gfx::end_frame (records the frame,
  hands it to the render worker thread, waits for a free frame slot when the worker lags). Texture acquire, encoding,
  queue submit and present run on the worker. perf-diag.log only has the sum.

  This patch measures every stage and logs one INFO line per second, ONLY when the main thread averages more than
  30 ms per frame in aurora_end_frame, so a smooth game writes nothing:
    [frame-stages] frames=N ms/frame: main: fifo+finish=.. imguiFreeze=.. rmlRecord=.. gfxEndFrame=.. | render thread: acquire=.. encode=.. submit=.. present=..
  gfxEndFrame is the main thread's wait for the worker (backpressure): large gfxEndFrame + large render-thread
  submit/present = the GPU/driver is the limit; large rmlRecord = RmlUi layout/geometry on the CPU.
  Logging only; no behavior change.

  Idempotent (marker dusk_xbox_frametimers). Exits 1 when an anchor does not match exactly once.
  extern/aurora/lib/aurora.cpp is in $alwaysFresh of Cache-Mtimes.ps1.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$marker = 'dusk_xbox_frametimers'
$rel = 'extern/aurora/lib/aurora.cpp'
$path = Join-Path $RepoRoot $rel
if (-not (Test-Path $path)) {
    Write-Host "::error::patch target missing: $rel"
    exit 1
}
$text = [System.IO.File]::ReadAllText($path)
if ($text.Contains($marker)) {
    Write-Host "already patched: $rel"
    exit 0
}

$inc = @'
#include <aurora/aurora.h>
#include <atomic>   // dusk_xbox_frametimers
#include <chrono>
'@
$helper = @'
constexpr Module Log{"aurora"};

// dusk_xbox_frametimers (platforms/xbox/Apply-Patches-FrameTimers.ps1)
using DuskStageClock = std::chrono::steady_clock;
// 0 fifo+finish, 1 imgui freeze, 2 rmlui record, 3 gfx::end_frame (main thread), 4..7 render thread: acquire, encode, submit, present
std::atomic<long long> g_dskStageUs[8];
std::atomic<long long> g_dskFrames{0};
DuskStageClock::time_point g_dskReportT0 = DuskStageClock::now();
inline DuskStageClock::time_point dsk_now() { return DuskStageClock::now(); }
inline void dsk_add(int i, DuskStageClock::time_point t0) {
  g_dskStageUs[i].fetch_add(
      std::chrono::duration_cast<std::chrono::microseconds>(DuskStageClock::now() - t0).count(),
      std::memory_order_relaxed);
}
void dsk_report() {
  const auto now = DuskStageClock::now();
  if (now - g_dskReportT0 < std::chrono::seconds(1)) {
    return;
  }
  g_dskReportT0 = now;
  const long long frames = g_dskFrames.exchange(0, std::memory_order_relaxed);
  long long us[8];
  for (int i = 0; i < 8; ++i) {
    us[i] = g_dskStageUs[i].exchange(0, std::memory_order_relaxed);
  }
  if (frames <= 0) {
    return;
  }
  const double n = static_cast<double>(frames) * 1000.0;
  const double mainMs = static_cast<double>(us[0] + us[1] + us[2] + us[3]) / n;
  if (mainMs < 30.0) {
    return;
  }
  Log.info("[frame-stages] frames={} ms/frame: main: fifo+finish={:.1f} imguiFreeze={:.1f} rmlRecord={:.1f} "
           "gfxEndFrame={:.1f} (total {:.1f}) | render thread: acquire={:.1f} encode={:.1f} submit={:.1f} present={:.1f}",
      frames, us[0] / n, us[1] / n, us[2] / n, us[3] / n, mainMs, us[4] / n, us[5] / n, us[6] / n, us[7] / n);
}
'@
$r = @{}
$r['drain'] = @'
  dsk_report();
  g_dskFrames.fetch_add(1, std::memory_order_relaxed);
  const auto dskT0 = dsk_now();
  gx::fifo::drain();
'@
$r['finish'] = @'
  gfx::finish();
  dsk_add(0, dskT0);
  const auto dskT1 = dsk_now();
'@
$r['freeze'] = @'
  auto imguiDrawData = imgui::freeze();
  dsk_add(1, dskT1);
'@
$r['rml0'] = @'
    const auto dskR0 = dsk_now();
    auto rmlFrame = rmlui::record_frame(viewport);
'@
$r['rml1'] = @'
    rmlOverlay = rmlFrame.overlay;
    dsk_add(2, dskR0);
'@
$r['gfx0'] = @'
  const auto dskG0 = dsk_now();
  gfx::end_frame([rmlBindGroup = std::move(rmlBindGroup), rmlOverlay, viewport,
'@
$r['gfx1'] = @'
  });
  dsk_add(3, dskG0);

#endif
}
} // namespace
} // namespace aurora
'@
$r['tex0'] = @'
    const auto dskC0 = dsk_now();
    wgpu::Texture currentTexture;
'@
$r['tex1'] = @'
    dsk_add(4, dskC0);
    const auto dskE0 = dsk_now();
    const bool canPresent = currentTexture && currentView;
'@
$r['enc1'] = @'
    dsk_add(5, dskE0);
    webgpu::gpu_prof::frame_end(encoder);
'@
$r['sub'] = @'
      const auto dskS0 = dsk_now();
      g_queue.Submit(1, &buffer);
      dsk_add(6, dskS0);
'@
$r['pres'] = @'
          const auto dskP0 = dsk_now();
          status = g_surface.Present();
          dsk_add(7, dskP0);
'@

$edits = @(
    @{ P = '(?m)^#include <aurora/aurora\.h>(?=\r?$)'; R = $inc.TrimEnd() },
    @{ P = '(?m)^constexpr Module Log\{"aurora"\};(?=\r?$)'; R = $helper.TrimEnd() },
    @{ P = '(?m)^  gx::fifo::drain\(\);(?=\r?$)'; R = $r['drain'].TrimEnd() },
    @{ P = '(?m)^  gfx::finish\(\);(?=\r?$)'; R = $r['finish'].TrimEnd() },
    @{ P = '(?m)^  auto imguiDrawData = imgui::freeze\(\);(?=\r?$)'; R = $r['freeze'].TrimEnd() },
    @{ P = '(?m)^    auto rmlFrame = rmlui::record_frame\(viewport\);(?=\r?$)'; R = $r['rml0'].TrimEnd() },
    @{ P = '(?m)^    rmlOverlay = rmlFrame\.overlay;(?=\r?$)'; R = $r['rml1'].TrimEnd() },
    @{ P = '(?m)^  gfx::end_frame\(\[rmlBindGroup = std::move\(rmlBindGroup\), rmlOverlay, viewport,(?=\r?$)'; R = $r['gfx0'].TrimEnd() },
    @{ P = '(?m)^  \}\);\r?\n\r?\n#endif\r?\n\}\r?\n\} // namespace\r?\n\} // namespace aurora(?=\r?$)'; R = $r['gfx1'].TrimEnd() },
    @{ P = '(?m)^    wgpu::Texture currentTexture;(?=\r?$)'; R = $r['tex0'].TrimEnd() },
    @{ P = '(?m)^    const bool canPresent = currentTexture && currentView;(?=\r?$)'; R = $r['tex1'].TrimEnd() },
    @{ P = '(?m)^    webgpu::gpu_prof::frame_end\(encoder\);(?=\r?$)'; R = $r['enc1'].TrimEnd() },
    @{ P = '(?m)^      g_queue\.Submit\(1, &buffer\);(?=\r?$)'; R = $r['sub'].TrimEnd() },
    @{ P = '(?m)^          status = g_surface\.Present\(\);(?=\r?$)'; R = $r['pres'].TrimEnd() }
)
$ok = $true
foreach ($e in $edits) {
    $count = [regex]::Matches($text, $e.P).Count
    if ($count -ne 1) {
        Write-Host "::error::patch anchor '$($e.P)' in $rel matched $count time(s), expected 1 (upstream changed?)"
        $ok = $false
    }
}
if (-not $ok) { exit 1 }
foreach ($e in $edits) {
    $text = [regex]::Replace($text, $e.P, $e.R.Replace('$', '$$'))
}
[System.IO.File]::WriteAllText($path, $text, $utf8)
Write-Host "patched: $rel ($($edits.Count) edit(s), frame stage timers)"
exit 0
