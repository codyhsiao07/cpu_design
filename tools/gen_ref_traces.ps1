param(
  [string[]]$Tests = @("24","25","26","27"),
  [string]$OutDir = "build_ref_traces",
  [int]$MaxSteps = 500000,
  [string]$PythonExe = "python",
  [int]$AllowMiss = 1
)

$ErrorActionPreference = "Stop"

function Parse-TestList([string[]]$listIn) {
  $items = @()
  foreach ($s in $listIn) {
    foreach ($tok in (($s -replace ","," " -replace ";"," ") -split "\s+")) {
      $t = $tok.Trim()
      if ($t -ne "") {
        $items += [int]$t
      }
    }
  }
  return $items
}

$tests = Parse-TestList -listIn $Tests
if ($tests.Count -eq 0) { throw "No valid tests in -Tests" }

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$gen = Join-Path $PSScriptRoot "gen_ref_trace_rv32i.py"

$rows = @()
foreach ($t in $tests) {
  $out = Join-Path $OutDir ("t{0}.trace" -f $t)
  $args = @($gen, "--test", "$t", "--max-steps", "$MaxSteps", "--out", $out)
  if ($AllowMiss -ne 0) {
    $args += "--allow-miss"
  }
  $lines = & $PythonExe @args 2>&1
  $txt = ($lines -join "`n")
  $status = if ($txt -match "REF_TRACE_OK") { "OK" } elseif ($txt -match "REF_TRACE_MISS") { "MISS" } else { "FAIL" }
  $rows += [pscustomobject]@{
    Test   = $t
    Status = $status
    Trace  = $out
    Info   = $txt
  }
  Write-Host ("[REF] TEST={0} -> {1}" -f $t, $status)
}

$csv = Join-Path $OutDir "summary.csv"
$txt = Join-Path $OutDir "summary.txt"
$rows | Export-Csv -NoTypeInformation -Path $csv

$summary = @()
$summary += ("Tests: {0}" -f ($tests -join ","))
$summary += ("OutDir: {0}" -f $OutDir)
$summary += ("CSV: {0}" -f $csv)
$summary += ""
foreach ($r in $rows) {
  $summary += ("TEST={0} STATUS={1} TRACE={2}" -f $r.Test, $r.Status, $r.Trace)
}
$summary | Set-Content -Path $txt
$summary | ForEach-Object { Write-Host $_ }

$failN = ($rows | Where-Object { $_.Status -eq "FAIL" }).Count
if ($failN -gt 0) { exit 1 }
exit 0

