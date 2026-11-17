<#
.SYNOPSIS
  Two CPU work-reduction changes taken from the fork 999sian/dusklight (also an Xbox One S port), applied as
  idempotent text patches. Called by Apply-Patches-Disc.ps1, i.e. from ci.ps1 before configure.
  Both are plain allocation / search reductions that keep behaviour; neither is measured on hardware yet.

  1. extern/aurora/lib/gfx/pipeline_cache.cpp (+ new header lib/gfx/pipeline_queue.hpp)
     (fork commit 999sian/aurora cc1c53de, same base as our pinned aurora 3227d76c).
     Promoting a pending pipeline (a draw needs a pipeline that is still waiting in the background compile
     queue) searched the whole background deque linearly, under the pipeline mutex, every time. The pending
     set becomes a map whose value says "currently in the background queue", so the search only happens
     when the pipeline really is there. This matters while shaders compile on the One S (thousands of queued
     pipelines).
  2. src/dusk/interp/frame_interpolation.cpp (fork commit fe90e45, same base file as ours).
     The per-frame matrix recording maps were destroyed and re-allocated every tick. They are now swapped
     and emptied with a full-range erase, which keeps Abseil's backing allocation. The history reset still
     frees the replacement map.

  NOT taken on purpose: FIFO draw batching (kDrawBatchSize 4, needs an A/B on hardware), material
  recording pool (animated-material correctness cannot be checked remotely), texture request/publication
  changes (only matter with texture packs), HUD guards.

  Idempotent (marker dusk_xbox_cpu / pipeline_queue.hpp). Exits 1 when an anchor does not match exactly as
  often as expected. Both patched files must be listed in $alwaysFresh of Cache-Mtimes.ps1.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$script:failed = $false
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Patch-Cpu([string]$Rel, [string]$Marker, [object[]]$Edits) {
    $path = Join-Path $RepoRoot $Rel
    if (-not (Test-Path $path)) {
        Write-Host "::error::patch target missing: $Rel"
        $script:failed = $true
        return
    }
    $text = [System.IO.File]::ReadAllText($path)
    if ($text.Contains($Marker)) {
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
        $text = [regex]::Replace($text, $e.Pattern, $e.Replacement)
    }
    [System.IO.File]::WriteAllText($path, $text, $utf8)
    Write-Host "patched: $Rel ($($Edits.Count) edit(s))"
}

# --- 1. aurora pipeline queue ------------------------------------------------------------------
$queueHeader = @'
#pragma once

#include <algorithm>
#include <utility>

namespace aurora::gfx::detail {
// Called with the pipeline mutex held; pending values track background queue membership.
template <typename Key, typename Queue, typename Pending>
void promote_pending_pipeline(Key hash, bool blocking, Queue& background, Queue& priority, Pending& pending) {
  const auto pendingIt = pending.find(hash);
  if (pendingIt == pending.end() || !pendingIt->second) {
    return;
  }
  auto backgroundIt = std::find_if(background.begin(), background.end(),
                                   [=](const auto& entry) { return entry.hash == hash; });
  if (backgroundIt == background.end()) {
    return;
  }
  if (blocking) {
    priority.emplace_front(std::move(*backgroundIt));
  } else {
    priority.emplace_back(std::move(*backgroundIt));
  }
  background.erase(backgroundIt);
  pendingIt->second = false;
}
} // namespace aurora::gfx::detail
'@
$queuePath = Join-Path $RepoRoot 'extern/aurora/lib/gfx/pipeline_queue.hpp'
if (Test-Path (Split-Path $queuePath)) {
    [System.IO.File]::WriteAllText($queuePath, ($queueHeader.TrimEnd() + "`n"), $utf8)
    Write-Host "wrote: extern/aurora/lib/gfx/pipeline_queue.hpp"
} else {
    Write-Host "::error::extern/aurora/lib/gfx is missing (is the submodule checked out?)"
    $script:failed = $true
}

$promoteOld = '(?m)^  auto backgroundIt = find_pending_pipeline\(g_backgroundPipelineQueue, hash\);\r?\n' +
              '  if \(backgroundIt == g_backgroundPipelineQueue\.end\(\)\) \{\r?\n' +
              '    return;\r?\n' +
              '  \}\r?\n' +
              '  if \(priority == PipelinePriority::Blocking\) \{\r?\n' +
              '    g_pipelineQueue\.emplace_front\(std::move\(\*backgroundIt\)\);\r?\n' +
              '  \} else \{\r?\n' +
              '    g_pipelineQueue\.emplace_back\(std::move\(\*backgroundIt\)\);\r?\n' +
              '  \}\r?\n' +
              '  g_backgroundPipelineQueue\.erase\(backgroundIt\);(?=\r?$)'
$promoteNew = @'
  detail::promote_pending_pipeline(hash, priority == PipelinePriority::Blocking, g_backgroundPipelineQueue,
                                   g_pipelineQueue, g_pendingPipelines);
'@
$pipelineEdits = @(
    @{ Pattern = '(?m)^#include "pipeline_cache\.hpp"(?=\r?$)'; Replacement = "#include `"pipeline_cache.hpp`"`n#include `"pipeline_queue.hpp`""; Expected = 1 },
    @{ Pattern = '(?m)^static absl::flat_hash_set<PipelineRef> g_pendingPipelines;(?=\r?$)';
       Replacement = "// The value is true only while the pending pipeline is queued in the background.`nstatic absl::flat_hash_map<PipelineRef, bool> g_pendingPipelines;"; Expected = 1 },
    @{ Pattern = $promoteOld; Replacement = $promoteNew.TrimEnd(); Expected = 1 },
    @{ Pattern = '(?m)^      g_pendingPipelines\.insert\(runtimeKey\);(?=\r?$)';
       Replacement = '      g_pendingPipelines.emplace(runtimeKey, priority == PipelinePriority::Background);'; Expected = 1 },
    @{ Pattern = '(?m)^      source\.pop_front\(\);(?=\r?$)';
       Replacement = "      source.pop_front();`n      g_pendingPipelines.at(pending.hash) = false;"; Expected = 1 }
)
Patch-Cpu 'extern/aurora/lib/gfx/pipeline_cache.cpp' 'pipeline_queue.hpp' $pipelineEdits

# --- 2. game: matrix recording maps ------------------------------------------------------------
$interpEdits = @(
    @{ Pattern = '(?m)^void clear_replacements\(\) \{\r?\n    g_replacements\.clear\(\);(?=\r?$)';
       Replacement = "void clear_replacements() {`n    // dusk_xbox_cpu: unlike clear(), full-range erase retains Abseil's backing allocation.`n    g_replacements.erase(g_replacements.begin(), g_replacements.end());"; Expected = 1 },
    @{ Pattern = '(?m)^    clear_replacements\(\);(?=\r?\n    clear_callbacks\(\);)';
       Replacement = '    g_replacements = {};'; Expected = 1 },
    @{ Pattern = '(?m)^    s_previousRecording = std::move\(s_currentRecording\);\r?\n    s_currentRecording = \{\};(?=\r?$)';
       Replacement = "    s_previousRecording.matrix_values.swap(s_currentRecording.matrix_values);`n    s_currentRecording.matrix_values.erase(s_currentRecording.matrix_values.begin(),`n                                          s_currentRecording.matrix_values.end());"; Expected = 1 }
)
Patch-Cpu 'src/dusk/interp/frame_interpolation.cpp' 'dusk_xbox_cpu' $interpEdits

if ($script:failed) { exit 1 }
exit 0
