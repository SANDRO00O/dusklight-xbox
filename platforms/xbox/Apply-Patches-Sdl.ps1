<#
.SYNOPSIS
  Patches the SDL3-uwp clone (build/ext/SDL3-uwp). Called by Apply-Patches-Disc.ps1, i.e. from ci.ps1 before configure.

  FOUND ON HARDWARE (build b67e3117, crash-diag.log): after "Continue anyway" the game thread sat forever in
    SDL_OpenAudioDeviceStream -> SDL_OpenAudioDevice -> WASAPI_OpenDevice -> WASAPI_ProxyToManagementThread
    -> SDL_WaitSemaphore
  and the WASAPI management thread sat in
    ManagementThreadMainloop -> WASAPI_ActivateDevice -> WASAPI_PrepDevice -> WASAPI_ProxyToManagementThread
    -> SDL_WaitSemaphore
  i.e. the management thread queued a task for itself and waited for it. SDL_wasapi.c avoids that with
    if (wait_on_result && SDL_GetCurrentThreadID() == SDL_GetThreadID(ManagementThread)) { run the task inline }
  but this fork's std::thread backend (src/thread/stdcpp/SDL_systhread.cpp) never fills in SDL_Thread::threadid
  (SDL_RunThread does not either), so SDL_GetThreadID(ManagementThread) is 0, the test is false, and the app
  freezes with a black screen right after the logo scene is created (the game initialises audio there).
  Fix: RunThread() stores the thread id before running the thread function.

  Idempotent (marker dusk_xbox_threadid). Exits 1 when the anchor does not match exactly once.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path,
    [string]$SdlDir = ''
)

$ErrorActionPreference = 'Stop'
if (-not $SdlDir) { $SdlDir = Join-Path $RepoRoot 'build/ext/SDL3-uwp' }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$marker = 'dusk_xbox_threadid'

$path = Join-Path $SdlDir 'src/thread/stdcpp/SDL_systhread.cpp'
if (-not (Test-Path $path)) {
    Write-Host "::error::patch target missing: $path (is the SDL3-uwp clone there?)"
    exit 1
}
$text = [System.IO.File]::ReadAllText($path)
if ($text.Contains($marker)) {
    Write-Host "already patched: $path"
    exit 0
}

$pattern = '(?s)static void RunThread\(void \*args\)\s*\{\s*SDL_RunThread\(\(SDL_Thread \*\)args\);\s*\}'
$count = [regex]::Matches($text, $pattern).Count
if ($count -ne 1) {
    Write-Host "::error::patch anchor RunThread() in $path matched $count time(s), expected 1 (upstream changed?)"
    exit 1
}

$replacement = @'
static void RunThread(void *args)
{
    // dusk_xbox_threadid: this backend never set SDL_Thread::threadid, so SDL_GetThreadID(thread) was 0 and
    // WASAPI_ProxyToManagementThread (SDL_wasapi.c) could not tell it was already running on the management
    // thread: it queued a task for itself and waited forever (SDL_OpenAudioDevice hung on the console).
    ((SDL_Thread *)args)->threadid = SDL_GetCurrentThreadID();
    SDL_RunThread((SDL_Thread *)args);
}
'@
$text = [regex]::Replace($text, $pattern, $replacement.TrimEnd())
[System.IO.File]::WriteAllText($path, $text, $utf8)
Write-Host "patched: $path (RunThread sets SDL_Thread::threadid)"
exit 0
