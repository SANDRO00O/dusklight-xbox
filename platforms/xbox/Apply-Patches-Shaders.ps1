<#
.SYNOPSIS
  Shader (pipeline) warmup changes for the Xbox One S. Called by Apply-Patches-Disc.ps1, i.e. from ci.ps1
  before configure. Patches extern/aurora/lib/gfx/pipeline_cache.cpp, after Apply-Patches-Cpu.ps1 has
  patched it (the anchors below are on lines that script does not touch).

  BACKGROUND (read from Aurora's source, not measured yet): the game compiles every material combination
  ("pipeline") it sees into a D3D12 pipeline state. A draw whose pipeline is not ready yet is skipped, which
  is the pop-in / "Compiling N shaders" the user sees while playing. Aurora already keeps the list of used
  pipelines on disk (pipeline_cache.db), recompiles that list in the background at every start, and can be
  seeded with a bundled list (initial_pipeline_cache.db, see Fetch-PipelineSeed.ps1). The compiled result
  itself cannot be kept between runs on this console: Dawn's pipeline-blob store calls
  ID3D12PipelineState::GetCachedBlob, which faults in the Xbox One S driver (see Apply-Patches.ps1).

  1. Order. The bundled list is in the order of an upstream playthrough (first_frame_used). Rows that come
     from the bundled list get 0x40000000 added to that number, so they sort AFTER every pipeline this console
     has really used (those keep the small frame number of their first use; the cache keeps the smaller one).
     The background warmup therefore rebuilds what this player already needs first, then works through the rest
     of the game in story order.
  2. Priority. The pipeline thread runs at low priority while it works through the background queue and at
     normal priority for a pipeline that a draw is waiting for, so the warmup does not take CPU from the game and
     render threads.
  3. Timing. Logs how long pipelines take to build ("pipeline build: N built, M still queued, avg X ms, max Y
     ms" every 100 pipelines and when the queue runs empty), to size the warmup on real hardware.

  Idempotent (marker dusk_xbox_shaders). Exits 1 when an anchor does not match exactly once. The patched
  file is listed in $alwaysFresh of Cache-Mtimes.ps1.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$marker = 'dusk_xbox_shaders'
$rel = 'extern/aurora/lib/gfx/pipeline_cache.cpp'

$path = Join-Path $RepoRoot $rel
if (-not (Test-Path $path)) {
    Write-Host "::error::patch target missing: $rel (is the submodule checked out?)"
    exit 1
}
$text = [System.IO.File]::ReadAllText($path)
if ($text.Contains($marker)) {
    Write-Host "already patched: $rel"
    exit 0
}

$incChrono = @'
#include <atomic>
#include <chrono>
'@
$incSdlThread = @'
#include <SDL3/SDL_iostream.h>
#include <SDL3/SDL_thread.h>
'@
$seedOrder = @'
$1// dusk_xbox_shaders: rows of the bundled list sort after every pipeline this console has used itself.
$1.firstFrameUsed = static_cast<uint32_t>(std::min<uint64_t>(
$1    static_cast<uint64_t>(firstFrameUsedValue) + 0x40000000ull, std::numeric_limits<uint32_t>::max())),
'@
$helper = @'
// dusk_xbox_shaders: how long pipelines take to build (see Apply-Patches-Shaders.ps1).
static void dusk_log_pipeline_built(std::chrono::steady_clock::duration took) {
  static uint32_t built = 0;
  static double totalMs = 0.0;
  static double maxMs = 0.0;
  const double ms = std::chrono::duration<double, std::milli>(took).count();
  ++built;
  totalMs += ms;
  maxMs = std::max(maxMs, ms);
  const uint32_t queued = detail::resources().stats.queuedPipelines;
  const bool idle = queued <= 1;
  if (built % 100 == 0 || (idle && built >= 20)) {
    Log.info("pipeline build: {} built, {} still queued, avg {:.0f} ms, max {:.0f} ms", built,
             queued > 0 ? queued - 1 : 0, totalMs / built, maxMs);
  }
  if (idle) {
    built = 0;
    totalMs = 0.0;
    maxMs = 0.0;
  }
}

static void pipeline_worker() {
'@
$hasMore = @'
  // dusk_xbox_shaders: background warmup runs at low priority, a pipeline a draw waits for at normal priority.
  bool duskIsBackground = false;
  bool duskLowPriority = false;
  bool hasMore = false;
'@
$sourcePick = @'
      auto& source = !g_pipelineQueue.empty() ? g_pipelineQueue : g_backgroundPipelineQueue;
      duskIsBackground = &source == &g_backgroundPipelineQueue;
'@
$build = @'
#ifdef DUSK_XBOX_UWP
    if (g_hasPipelineThread && duskIsBackground != duskLowPriority) {
      duskLowPriority = duskIsBackground;
      SDL_SetCurrentThreadPriority(duskLowPriority ? SDL_THREAD_PRIORITY_LOW : SDL_THREAD_PRIORITY_NORMAL);
    }
#endif
    const auto duskBuildStart = std::chrono::steady_clock::now();
    auto result = pending.create();
    const auto pipelineCount = result.pipeline_count();
    dusk_log_pipeline_built(std::chrono::steady_clock::now() - duskBuildStart);
'@

$edits = @(
    @{ Pattern = '(?m)^#include <atomic>\r?\n#include <condition_variable>(?=\r?$)'; Replacement = ($incChrono.TrimEnd() + "`n#include <condition_variable>"); Expected = 1 },
    @{ Pattern = '(?m)^#include <SDL3/SDL_iostream\.h>(?=\r?$)'; Replacement = $incSdlThread.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^([ \t]+)\.firstFrameUsed = static_cast<uint32_t>\(firstFrameUsedValue\),(?=\r?$)'; Replacement = $seedOrder.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^static void pipeline_worker\(\) \{(?=\r?$)'; Replacement = $helper.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^  bool hasMore = false;(?=\r?$)'; Replacement = $hasMore.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^      auto& source = !g_pipelineQueue\.empty\(\) \? g_pipelineQueue : g_backgroundPipelineQueue;(?=\r?$)'; Replacement = $sourcePick.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^    auto result = pending\.create\(\);\r?\n    const auto pipelineCount = result\.pipeline_count\(\);(?=\r?$)'; Replacement = $build.TrimEnd(); Expected = 1 }
)

foreach ($e in $edits) {
    $count = [regex]::Matches($text, $e.Pattern).Count
    if ($count -ne $e.Expected) {
        Write-Host "::error::patch anchor '$($e.Pattern)' in $rel matched $count time(s), expected $($e.Expected) (upstream changed?)"
        exit 1
    }
}
foreach ($e in $edits) {
    $text = [regex]::Replace($text, $e.Pattern, $e.Replacement)
}
[System.IO.File]::WriteAllText($path, $text, $utf8)
Write-Host "patched: $rel ($($edits.Count) edit(s): bundled-list order, pipeline thread priority, build timing log)"
exit 0
