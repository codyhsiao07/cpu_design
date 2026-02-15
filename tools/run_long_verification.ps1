param(
  [string[]]$Tests = @("24","25","26","27"),
  [int]$SeedStart = 1,
  [int]$SeedCount = 100,
  [string]$OutDir = "build_long_verification",
  [string]$SimExe = "simv",
  [string]$Iverilog = "iverilog",
  [string]$Vvp = "vvp",
  [int]$Compile = 1,
  [int]$RandMem = 1,
  [int]$RandBpPct = 15,
  [int]$RandIMax = 9,
  [int]$RandDMax = 9,
  [int]$AssertEn = 1,
  [int]$StallWdog = 512,
  [int]$RdWdog = 256,
  [int]$MaxCycles = 250000,
  [int]$TraceSeed = 1,
  [string]$RefTraceDir = "",
  [string]$PythonExe = "python",
  [int]$DiffSquashDup = 1
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

function Invoke-SimOne {
  param(
    [int]$TestId,
    [int]$Seed,
    [string]$TracePath,
    [string]$CovPath,
    [string]$LogPath
  )
  $plus = @(
    "+TEST=$TestId",
    "+MAXCYCLES=$MaxCycles",
    "+RAND_MEM=$RandMem",
    "+SEED=$Seed",
    "+RAND_BP_PCT=$RandBpPct",
    "+RAND_I_MAX=$RandIMax",
    "+RAND_D_MAX=$RandDMax",
    "+ASSERT_EN=$AssertEn",
    "+STALL_WDOG=$StallWdog",
    "+RD_WDOG=$RdWdog",
    "+TRACE_EN=1",
    "+TRACE_FILE=$TracePath",
    "+COV_EN=1",
    "+COV_FILE=$CovPath"
  )
  $lines = & $Vvp $SimExe @plus 2>&1
  $lines | Set-Content -Path $LogPath
  $hasPass = $false
  $hasFail = $false
  foreach ($ln in $lines) {
    if ($ln -match "PASS:\s+test") { $hasPass = $true }
    if ($ln -match "ASSERT_FAIL|TIMEOUT|FATAL|FAIL") { $hasFail = $true }
  }
  if ($hasPass -and -not $hasFail) { return "PASS" }
  return "FAIL"
}

function Parse-CovFile {
  param([string]$Path)
  $m = @{}
  if (!(Test-Path $Path)) { return $m }
  foreach ($ln in (Get-Content $Path)) {
    if ($ln -match "^\s*([A-Za-z0-9_]+)\s*=\s*(.+)\s*$") {
      $m[$matches[1]] = $matches[2]
    }
  }
  return $m
}

$tests = Parse-TestList -listIn $Tests
if ($tests.Count -eq 0) { throw "No valid tests in -Tests" }

$rootOut = New-Item -ItemType Directory -Path $OutDir -Force
$regDir  = Join-Path $rootOut "regression"
$traceDir = Join-Path $rootOut "traces"
$covDir   = Join-Path $rootOut "coverage"
$diffDir  = Join-Path $rootOut "diff"
New-Item -ItemType Directory -Path $regDir -Force | Out-Null
New-Item -ItemType Directory -Path $traceDir -Force | Out-Null
New-Item -ItemType Directory -Path $covDir -Force | Out-Null
New-Item -ItemType Directory -Path $diffDir -Force | Out-Null

$regScript = Join-Path $PSScriptRoot "run_multiseed_regression.ps1"
$cmpScript = Join-Path $PSScriptRoot "compare_commit_trace.py"

Write-Host "[LONG] Step1: multiseed regression"
& $regScript `
  -Tests $tests `
  -SeedStart $SeedStart `
  -SeedCount $SeedCount `
  -OutDir $regDir `
  -SimExe $SimExe `
  -Iverilog $Iverilog `
  -Vvp $Vvp `
  -Compile $Compile `
  -RandMem $RandMem `
  -RandBpPct $RandBpPct `
  -RandIMax $RandIMax `
  -RandDMax $RandDMax `
  -AssertEn $AssertEn `
  -StallWdog $StallWdog `
  -RdWdog $RdWdog `
  -MaxCycles $MaxCycles

if ($LASTEXITCODE -ne 0) {
  Write-Host "[LONG] regression failed, skip trace/diff"
  exit $LASTEXITCODE
}

Write-Host "[LONG] Step2: trace + coverage capture"
$traceRows = @()
foreach ($t in $tests) {
  $tracePath = Join-Path $traceDir ("t{0}_s{1}.trace" -f $t, $TraceSeed)
  $covPath   = Join-Path $covDir   ("t{0}_s{1}.cov" -f $t, $TraceSeed)
  $logPath   = Join-Path $traceDir ("t{0}_s{1}.log" -f $t, $TraceSeed)
  $st = Invoke-SimOne -TestId $t -Seed $TraceSeed -TracePath $tracePath -CovPath $covPath -LogPath $logPath
  $traceRows += [pscustomobject]@{
    Test   = $t
    Seed   = $TraceSeed
    Status = $st
    Trace  = $tracePath
    Cov    = $covPath
    Log    = $logPath
  }
  Write-Host ("[LONG] TRACE TEST={0} SEED={1} -> {2}" -f $t, $TraceSeed, $st)
}

$traceCsv = Join-Path $traceDir "trace_summary.csv"
$traceRows | Export-Csv -NoTypeInformation -Path $traceCsv

Write-Host "[LONG] Step3: coverage summary"
$covRows = @()
foreach ($r in $traceRows) {
  $m = Parse-CovFile -Path $r.Cov
  $covRows += [pscustomobject]@{
    Test              = $r.Test
    Seed              = $r.Seed
    wb_commits        = $m["wb_commits"]
    i_req_hs          = $m["i_req_hs"]
    d_req_hs          = $m["d_req_hs"]
    i_rsp_hs          = $m["i_rsp_hs"]
    d_rsp_hs          = $m["d_rsp_hs"]
    max_i_req_stall   = $m["max_i_req_stall"]
    max_d_req_stall   = $m["max_d_req_stall"]
    max_i_rsp_stall   = $m["max_i_rsp_stall"]
    max_d_rsp_stall   = $m["max_d_rsp_stall"]
    i_rsp_err         = $m["i_rsp_err"]
    d_rsp_err         = $m["d_rsp_err"]
    ifetch_err        = $m["ifetch_err"]
    cov_file          = $r.Cov
  }
}
$covCsv = Join-Path $covDir "coverage_summary.csv"
$covRows | Export-Csv -NoTypeInformation -Path $covCsv

Write-Host "[LONG] Step4: differential compare"
$diffRows = @()
$pythonOk = $true
if (!(Get-Command $PythonExe -ErrorAction SilentlyContinue)) {
  $pythonOk = $false
}

foreach ($r in $traceRows) {
  $ref = ""
  $dst = Join-Path $diffDir ("t{0}_s{1}.diff.txt" -f $r.Test, $r.Seed)
  $status = "SKIP"
  if (($RefTraceDir -ne "") -and $pythonOk) {
    $cand = Join-Path $RefTraceDir ("t{0}.trace" -f $r.Test)
    if (Test-Path $cand) {
      $ref = $cand
      $cmpArgs = @($cmpScript)
      if ($DiffSquashDup -ne 0) {
        $cmpArgs += "--squash-dup"
      }
      $cmpArgs += @($ref, $r.Trace)
      $out = & $PythonExe @cmpArgs 2>&1
      $out | Set-Content -Path $dst
      if ($LASTEXITCODE -eq 0) { $status = "PASS" } else { $status = "FAIL" }
    } else {
      "SKIP: no ref trace $cand" | Set-Content -Path $dst
    }
  } else {
    "SKIP: RefTraceDir empty or python unavailable" | Set-Content -Path $dst
  }

  $diffRows += [pscustomobject]@{
    Test   = $r.Test
    Seed   = $r.Seed
    Status = $status
    Ref    = $ref
    Dut    = $r.Trace
    Report = $dst
  }
}

$diffCsv = Join-Path $diffDir "diff_summary.csv"
$diffRows | Export-Csv -NoTypeInformation -Path $diffCsv

$totalTrace = $traceRows.Count
$traceFail  = ($traceRows | Where-Object { $_.Status -eq "FAIL" }).Count
$diffFail   = ($diffRows  | Where-Object { $_.Status -eq "FAIL" }).Count

$report = @()
$report += "Long Verification Report"
$report += "tests=$($tests -join ',')"
$report += "seed_start=$SeedStart"
$report += "seed_count=$SeedCount"
$report += "trace_seed=$TraceSeed"
$report += "regression_summary=$(Join-Path $regDir 'summary.txt')"
$report += "trace_summary=$traceCsv"
$report += "coverage_summary=$covCsv"
$report += "diff_summary=$diffCsv"
$report += "trace_fail=$traceFail/$totalTrace"
$report += "diff_fail=$diffFail/$totalTrace"

$reportPath = Join-Path $OutDir "report.txt"
$report | Set-Content -Path $reportPath
$report | ForEach-Object { Write-Host $_ }

if (($traceFail -gt 0) -or ($diffFail -gt 0)) {
  exit 1
}
exit 0
