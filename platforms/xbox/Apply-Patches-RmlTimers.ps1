<#
.SYNOPSIS
  Timers inside rmlui::record_frame (extern/aurora/lib/rmlui.cpp). Called by Apply-Patches-Disc.ps1.

  FOUND ON HARDWARE ([frame-stages] lines of the dusklight log of 2026-11-28, Apply-Patches-FrameTimers.ps1):
  while a menu (the mods list) is open the main thread spends 40-60 ms per frame (spikes 300 ms - 1.1 s) in
  rmlui::record_frame, while the render thread is idle (submit ~3 ms, present ~0.6 ms, gfx::end_frame 0 ms).
  So it is CPU work in RmlUi, not the GPU. record_frame is  Context::Update()  (style + layout + animations),
  Context::Render()  (geometry, issues the render interface calls) and  renderInterface->EndFrame()  (backdrop
  filters / glass effect passes, final composition). This patch measures the three and logs once per second,
  only while the average is above 20 ms:
    [rml-stages] frames=N ms/frame: update=.. render=.. endFrame=.. backdrop=0/1
  Logging only; no behavior change.

  Idempotent (marker dusk_xbox_rmltimers). Exits 1 when an anchor does not match exactly once.
  extern/aurora/lib/rmlui.cpp is in $alwaysFresh of Cache-Mtimes.ps1.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$marker = 'dusk_xbox_rmltimers'
$rel = 'extern/aurora/lib/rmlui.cpp'
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

$r0 = @'
#include <chrono>
#include <cmath>
'@
$r1 = @'
Module Log("aurora::rmlui");

// dusk_xbox_rmltimers (platforms/xbox/Apply-Patches-RmlTimers.ps1)
using DuskRmlClock = std::chrono::steady_clock;
struct DuskRmlStats {
  double update = 0.0;
  double render = 0.0;
  double end = 0.0;
  long frames = 0;
  DuskRmlClock::time_point t0 = DuskRmlClock::now();
};
DuskRmlStats g_dskRml;
inline double dsk_rml_ms(DuskRmlClock::time_point a) {
  return std::chrono::duration<double, std::milli>(DuskRmlClock::now() - a).count();
}
void dsk_rml_report(bool backdrop) {
  ++g_dskRml.frames;
  const auto now = DuskRmlClock::now();
  if (now - g_dskRml.t0 < std::chrono::seconds(1)) {
    return;
  }
  const double n = static_cast<double>(g_dskRml.frames);
  const double total = (g_dskRml.update + g_dskRml.render + g_dskRml.end) / n;
  if (total > 20.0) {
    Log.info("[rml-stages] frames={} ms/frame: update={:.1f} render={:.1f} endFrame={:.1f} backdrop={}",
        g_dskRml.frames, g_dskRml.update / n, g_dskRml.render / n, g_dskRml.end / n, backdrop ? 1 : 0);
  }
  g_dskRml = DuskRmlStats{};
}
'@
$r2 = @'
  sync_context_metrics(dim);
  const auto dskU0 = DuskRmlClock::now();
  g_context->Update();
  g_dskRml.update += dsk_rml_ms(dskU0);
'@
$r3 = @'
  const auto dskR0 = DuskRmlClock::now();
  Backend::BeginFrame();
  g_context->Render();
  Backend::PresentFrame();
  g_dskRml.render += dsk_rml_ms(dskR0);
'@
$r4 = @'
  const auto dskE0 = DuskRmlClock::now();
  const bool dskEnded = renderInterface->EndFrame();
  g_dskRml.end += dsk_rml_ms(dskE0);
  dsk_rml_report(needsBackdrop);
  if (!dskEnded) {
'@

$edits = @(
    @{ P = '(?m)^#include <cmath>(?=\r?$)'; R = $r0.TrimEnd() },
    @{ P = '(?m)^Module Log\("aurora::rmlui"\);(?=\r?$)'; R = $r1.TrimEnd() },
    @{ P = '(?m)^  sync_context_metrics\(dim\);\r?\n  g_context->Update\(\);(?=\r?$)'; R = $r2.TrimEnd() },
    @{ P = '(?m)^  Backend::BeginFrame\(\);\r?\n  g_context->Render\(\);\r?\n  Backend::PresentFrame\(\);(?=\r?$)'; R = $r3.TrimEnd() },
    @{ P = '(?m)^  if \(!renderInterface->EndFrame\(\)\) \{(?=\r?$)'; R = $r4.TrimEnd() }
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
Write-Host "patched: $rel ($($edits.Count) edit(s), RmlUi stage timers)"
exit 0
