<#
.SYNOPSIS
  Memory card creation on the Xbox (UWP), with logging. Called by Apply-Patches-Disc.ps1 from ci.ps1.

  SYMPTOM (hardware): the game reports there is nowhere to save ("no slot", i.e. the card is not found).
  The card is a folder (<LocalState>/TwilitRealm/Dusklight/<region>/Card A). Aurora's CARDInit
  (extern/aurora/lib/dolphin/card.cpp) creates it only when
      !loadedCard && !std::filesystem::exists(cardPaths[0], ec) && !ec
  and ignores the result of format() and of the following open(), and logs nothing about any of it. So if
  exists() reports an error code, or SDL_CreateDirectory fails inside format(), the card silently never
  exists and CARDProbe keeps answering NOCARD.

  WHAT THIS DOES (UWP only, original code kept under #else):
    * logs the card path, whether it exists, any error from exists(), the format() result and whether
      the final open() worked (lines "CARD init: ..." in the Dusklight log);
    * does not let an error code from exists() block creating the card;
    * when format() fails, falls back to std::filesystem::create_directories() and logs its result.
  The root cause is not known yet; the new log lines will show it if this does not fix it.

  Idempotent (marker dusk_xbox_card). A changed upstream anchor only prints a warning (this is a
  defensive patch, it must not break the build). The patched file must be listed in $alwaysFresh of
  Cache-Mtimes.ps1.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$marker = 'dusk_xbox_card'
$rel = 'extern/aurora/lib/dolphin/card.cpp'

$path = Join-Path $RepoRoot $rel
if (-not (Test-Path $path)) {
    Write-Host "::warning::patch target missing: $rel (is the submodule checked out?)"
    exit 0
}
$text = [System.IO.File]::ReadAllText($path)
if ($text.Contains($marker)) {
    Write-Host "already patched: $rel"
    exit 0
}

$pattern = '(?m)^  std::error_code createError;\r?\n' +
           '  if \(!loadedCard && !std::filesystem::exists\(cardPaths\[0\], createError\) && !createError\) \{\r?\n' +
           '    CardChannels\[0\]->open\(cardPaths\[0\]\);\r?\n' +
           '    CardChannels\[0\]->format\(aurora::card::ECardSlot::SlotA\);\r?\n' +
           '    CardChannels\[0\]->close\(\);\r?\n' +
           '    CardChannels\[0\]->open\(cardPaths\[0\]\);\r?\n' +
           '  \}(?=\r?$)'
$count = [regex]::Matches($text, $pattern).Count
if ($count -ne 1) {
    Write-Host "::warning::card patch anchor matched $count time(s), expected 1 (upstream changed?); card creation NOT patched"
    exit 0
}

$replacement = @'
  std::error_code createError;
#ifdef DUSK_XBOX_UWP
  // dusk_xbox_card: log every step, do not let an exists() error code block creating the card, and fall
  // back to std::filesystem when format() cannot create the folder. See Apply-Patches-Card.ps1.
  const bool cardPathExists = std::filesystem::exists(cardPaths[0], createError);
  Log.info("CARD init: loadedCard={} path='{}' exists={} existsError='{}'", loadedCard,
           aurora::io::fs_path_to_string(cardPaths[0]), cardPathExists, createError.message());
  if (!loadedCard && !cardPathExists) {
    const bool openedEmpty = CardChannels[0]->open(cardPaths[0]);
    const auto formatResult = CardChannels[0]->format(aurora::card::ECardSlot::SlotA);
    Log.info("CARD init: open before format={} format result={}", openedEmpty, static_cast<int>(formatResult));
    if (formatResult != aurora::card::ECardResult::READY) {
      std::error_code mkError;
      std::filesystem::create_directories(cardPaths[0], mkError);
      std::error_code checkError;
      const bool nowExists = std::filesystem::exists(cardPaths[0], checkError);
      Log.warn("CARD init: create_directories fallback error='{}', exists now={}", mkError.message(), nowExists);
    }
    CardChannels[0]->close();
    const bool opened = CardChannels[0]->open(cardPaths[0]);
    Log.info("CARD init: open after format={}", opened);
  }
#else
  if (!loadedCard && !std::filesystem::exists(cardPaths[0], createError) && !createError) {
    CardChannels[0]->open(cardPaths[0]);
    CardChannels[0]->format(aurora::card::ECardSlot::SlotA);
    CardChannels[0]->close();
    CardChannels[0]->open(cardPaths[0]);
  }
#endif
'@
$text = [regex]::Replace($text, $pattern, $replacement.TrimEnd().Replace('$', '$$'))
[System.IO.File]::WriteAllText($path, $text, $utf8)
Write-Host "patched: $rel (card creation logging and fallback on UWP)"
exit 0
