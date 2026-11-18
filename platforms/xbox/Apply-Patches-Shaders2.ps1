<#
.SYNOPSIS
  Second pipeline-compile thread for the Xbox. Called by Apply-Patches-Disc.ps1 after
  Apply-Patches-Shaders.ps1 (its anchors include text that script adds). Patches
  extern/aurora/lib/gfx/pipeline_cache.cpp.

  WHY: Aurora compiles pipelines on ONE thread. In Game mode the console gives the app 4 exclusive + 2 shared
  cores, so most of them sit idle while ~2,700 pipelines are compiled one after another. Dawn allows
  CreateShaderModule / CreateRenderPipeline from several threads at once (the render thread already calls
  the device while the compile thread works), so a second thread that works through the BACKGROUND (warmup)
  queue roughly halves the warmup time if the cost is on the CPU side.

  SAFETY (read from the source, not tested on hardware):
    * Only GX pipelines are given to the helper (PendingPipeline::duskParallelSafe). The creator of GX
      pipelines uses locked bind-group-layout caches and no shared writable statics; RmlUi pipelines read
      global bind-group layouts without a lock and the clear pipelines are rare, so both stay on the
      original thread.
    * The helper never touches the priority queue and never blocks a draw: a pipeline a draw waits for is
      still built by the original thread at normal priority.
    * It waits on its own condition variable, so it cannot swallow a wake-up meant for the original thread.
    * The original thread no longer assumes the queue is non-empty after its own build (the helper may have
      drained it).
    * The build-timing statistics of Apply-Patches-Shaders.ps1 are guarded by a mutex.
    * The helper only starts when SDL reports at least 4 logical cores.
  If the console's driver does not like two simultaneous pipeline creations, the symptom would be a crash or
  hang in the first minutes (crash-diag.log); remove the call in Apply-Patches-Disc.ps1 to go back.

  Idempotent (marker dusk_xbox_parallel). Exits 1 when an anchor does not match exactly once. The patched
  file is already listed in $alwaysFresh of Cache-Mtimes.ps1.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$marker = 'dusk_xbox_parallel'
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
if (-not $text.Contains('dusk_xbox_shaders')) {
    Write-Host "::error::$rel is not patched by Apply-Patches-Shaders.ps1 yet (run it first)"
    exit 1
}

$incCpu = @'
#include <SDL3/SDL_thread.h>
#include <SDL3/SDL_cpuinfo.h>
'@
$pendingField = @'
  NewPipelineCallback create;
  bool duskParallelSafe = false; // dusk_xbox_parallel: may be built by the helper thread
};
'@
$implSig = @'
static PipelineRef find_pipeline_impl(PipelineRef runtimeKey, NewPipelineCallback&& cb,
                                      PipelinePriority priority = PipelinePriority::Normal,
                                      bool duskParallelSafe = false) {
'@
$pendingInit = @'
$1.create = std::move(cb),
$1.duskParallelSafe = duskParallelSafe,
'@
$gxCall = @'
  return find_pipeline_impl(runtimeKey, [config, layout] { return create_pipeline(config, layout); }, priority,
                            true /* dusk_xbox_parallel: GX pipelines only */);
'@
$statsLock = @'
  static std::mutex duskStatsMutex; // dusk_xbox_parallel: two threads report now
  std::lock_guard duskStatsLock{duskStatsMutex};
  static uint32_t built = 0;
'@
$helper = @'
// dusk_xbox_parallel: second compile thread, works through the background (warmup) queue only.
static std::thread g_duskHelperThread;
static std::condition_variable g_duskHelperCv;

static void dusk_pipeline_helper() {
#ifdef TRACY_ENABLE
  tracy::SetThreadName("Pipeline compilation helper");
#endif
  SDL_SetCurrentThreadPriority(SDL_THREAD_PRIORITY_LOW);
  while (true) {
    PendingPipeline pending;
    {
      std::unique_lock lock{g_pipelineMutex};
      auto it = g_backgroundPipelineQueue.end();
      while (!g_pipelineThreadEnd) {
        it = std::find_if(g_backgroundPipelineQueue.begin(), g_backgroundPipelineQueue.end(),
                          [](const PendingPipeline& p) { return p.duskParallelSafe; });
        if (it != g_backgroundPipelineQueue.end()) {
          break;
        }
        g_duskHelperCv.wait_for(lock, std::chrono::milliseconds(250));
      }
      if (g_pipelineThreadEnd) {
        return;
      }
      pending = std::move(*it);
      g_backgroundPipelineQueue.erase(it);
      g_pendingPipelines.at(pending.hash) = false;
    }
    const auto buildStart = std::chrono::steady_clock::now();
    auto result = pending.create();
    const auto pipelineCount = result.pipeline_count();
    dusk_log_pipeline_built(std::chrono::steady_clock::now() - buildStart);
    {
      std::lock_guard lock{g_pipelineMutex};
      g_pipelines.try_emplace(pending.hash, std::move(result));
      g_pendingPipelines.erase(pending.hash);
    }
    notify_pipeline_ready(true, pipelineCount);
  }
}

static void pipeline_worker() {
'@
$waitFix = @'
        if (!hasMore || (g_pipelineQueue.empty() && g_backgroundPipelineQueue.empty())) {
'@
$start = @'
    g_pipelineThread = std::thread(pipeline_worker);
#ifdef DUSK_XBOX_UWP
    // dusk_xbox_parallel: helper for the warmup queue when there are cores to spare.
    if (SDL_GetNumLogicalCPUCores() >= 4) {
      g_duskHelperThread = std::thread(dusk_pipeline_helper);
      Log.info("pipeline compile: helper thread started ({} logical cores)", SDL_GetNumLogicalCPUCores());
    } else {
      Log.info("pipeline compile: single thread ({} logical cores)", SDL_GetNumLogicalCPUCores());
    }
#endif
'@
$stop = @'
    g_pipelineThread.join();
    g_duskHelperCv.notify_all();
    if (g_duskHelperThread.joinable()) {
      g_duskHelperThread.join();
    }
'@

$edits = @(
    @{ Pattern = '(?m)^#include <SDL3/SDL_thread\.h>(?=\r?$)'; Replacement = $incCpu.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^  NewPipelineCallback create;\r?\n\};'; Replacement = $pendingField.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^static PipelineRef find_pipeline_impl\(PipelineRef runtimeKey, NewPipelineCallback&& cb,\r?\n[ \t]+PipelinePriority priority = PipelinePriority::Normal\) \{'; Replacement = $implSig.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^([ \t]+)\.create = std::move\(cb\),(?=\r?$)'; Replacement = $pendingInit.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^  return find_pipeline_impl\(runtimeKey, \[config, layout\] \{ return create_pipeline\(config, layout\); \}, priority\);(?=\r?$)'; Replacement = $gxCall.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^  static uint32_t built = 0;(?=\r?$)'; Replacement = $statsLock.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^static void pipeline_worker\(\) \{(?=\r?$)'; Replacement = $helper.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^        if \(!hasMore\) \{(?=\r?$)'; Replacement = $waitFix.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^    g_pipelineThread = std::thread\(pipeline_worker\);(?=\r?$)'; Replacement = $start.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^    g_pipelineThread\.join\(\);(?=\r?$)'; Replacement = $stop.TrimEnd(); Expected = 1 }
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
Write-Host "patched: $rel ($($edits.Count) edit(s): second pipeline compile thread for GX warmup)"
exit 0
