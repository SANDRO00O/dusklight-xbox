<#
.SYNOPSIS
  Turns the linker map of dusklight.exe (/MAP) into a compact symbol table, "<rva hex8> <decorated name>"
  per line, which the game packages as symbols/dusklight.sym. xbox_crash_diag.cpp reads it to print
  function names in crash / hang stack traces (crash-diag.log) instead of bare addresses.
  Called by ci.ps1 after the first build; the second build repackages the file into the .msix.
#>
param(
    [Parameter(Mandatory = $true)][string]$MapFile,
    [Parameter(Mandatory = $true)][string]$OutFile
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $MapFile)) {
    Write-Host "::warning::linker map not found: $MapFile"
    exit 1
}

# Publics lines look like:
#  0001:0003f2a0       ?foo@@YAXXZ                000000014004 0a a0 f   foo.obj
# (seg:offset, name, Rva+Base, flags "f" = function / "i" = inline, lib:object).
$re = [regex]::new('^\s*[0-9a-fA-F]{4}:[0-9a-fA-F]{8}\s+(\S+)\s+([0-9a-fA-F]{16})\s+f\s', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$baseRe = [regex]::new('Preferred load address is ([0-9a-fA-F]+)', [System.Text.RegularExpressions.RegexOptions]::Compiled)

$base = [uint64]0
$haveBase = $false
$count = 0
$writer = New-Object System.IO.StreamWriter($OutFile, $false, (New-Object System.Text.UTF8Encoding($false)))
try {
    foreach ($line in [System.IO.File]::ReadLines($MapFile)) {
        if (-not $haveBase) {
            $bm = $baseRe.Match($line)
            if ($bm.Success) {
                $base = [Convert]::ToUInt64($bm.Groups[1].Value, 16)
                $haveBase = $true
            }
            continue
        }
        $m = $re.Match($line)
        if (-not $m.Success) { continue }
        $addr = [Convert]::ToUInt64($m.Groups[2].Value, 16)
        if ($addr -lt $base) { continue }
        $name = $m.Groups[1].Value
        if ($name.Length -gt 240) { $name = $name.Substring(0, 240) }
        $writer.Write(('{0:x8} {1}' -f ($addr - $base), $name))
        $writer.Write("`n")
        $count++
    }
} finally {
    $writer.Dispose()
}

if (-not $haveBase) {
    Write-Host "::warning::no 'Preferred load address' line in $MapFile, symbol table is empty"
    exit 1
}
Write-Host ("symbols: {0:N0} function symbols written to {1}" -f $count, $OutFile)
exit 0
