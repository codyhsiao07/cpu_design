param(
  [string[]]$Tests = @("24","25","26","27"),
  [int]$SeedStart = 1,
  [int]$SeedCount = 20,
  [string]$OutDir = "build_multiseed",
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
  [string[]]$ExtraPlusarg = @()
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

function Compile-Sim {
  param(
    [string]$IverilogExe,
    [string]$OutSimExe
  )
  $src = @(
    "icache_pipeline_tb.v",
    "icache_pipeline_top.v",
    "icache_top.v",
    "icache.v",
    "IF.v",
    "IFID_register.v",
    "ID.v",
    "IDEX_register.v",
    "EX.v",
    "EXMEM_register.v",
    "MEM.v",
    "MEMWB_register.v",
    "WB.v",
    "hazard_unit.v",
    "forward_unit.v",
    "dcache.v",
    "L2_cache.v",
    "I_D_arbitration.v",
    "branch_predictor.v",
    "uart_rx.v",
    "uart_bootloader.v",
    "MIG_DDR2_interface.v"
  )
  & $IverilogExe "-g2005-sv" "-o" $OutSimExe @src
  if ($LASTEXITCODE -ne 0) {
    throw "Compile failed."
  }
}

function Run-One {
  param(
    [string]$VvpExe,
    [string]$Sim,
    [int]$TestId,
    [int]$Seed,
    [int]$UseRandMem,
    [int]$BpPct,
    [int]$IMax,
    [int]$DMax,
    [int]$AsrtEn,
    [int]$Swdog,
    [int]$RwDog,
    [int]$Mcycles,
    [string[]]$Extra,
    [string]$LogPath
  )
  $plus = @("+TEST=$TestId")
  if ($Mcycles -gt 0) {
    $plus += "+MAXCYCLES=$Mcycles"
  }
  if ($UseRandMem -ne 0) {
    $plus += "+RAND_MEM=1"
    $plus += "+SEED=$Seed"
    $plus += "+RAND_BP_PCT=$BpPct"
    $plus += "+RAND_I_MAX=$IMax"
    $plus += "+RAND_D_MAX=$DMax"
    $plus += "+ASSERT_EN=$AsrtEn"
    $plus += "+STALL_WDOG=$Swdog"
    $plus += "+RD_WDOG=$RwDog"
  } else {
    $plus += "+ASSERT_EN=$AsrtEn"
  }
  if ($Extra) {
    $plus += $Extra
  }

  $lines = & $VvpExe $Sim @plus 2>&1
  $lines | Set-Content -Path $LogPath

  $hasPass = $false
  $hasFail = $false
  foreach ($ln in $lines) {
    if ($ln -match "PASS:\s+test") {
      $hasPass = $true
    }
    if ($ln -match "ASSERT_FAIL|TIMEOUT|FATAL|FAIL") {
      $hasFail = $true
    }
  }

  if ($hasPass -and -not $hasFail) { return "PASS" }
  return "FAIL"
}

$tests = Parse-TestList -listIn $Tests
if ($tests.Count -eq 0) {
  throw "No valid tests in -Tests"
}
if ($SeedCount -le 0) {
  throw "SeedCount must be > 0"
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

if ($Compile -ne 0) {
  Write-Host "[REG] Compiling..."
  Compile-Sim -IverilogExe $Iverilog -OutSimExe $SimExe
}

$rows = @()
$startTs = Get-Date

for ($s = $SeedStart; $s -lt ($SeedStart + $SeedCount); $s++) {
  foreach ($t in $tests) {
    $log = Join-Path $OutDir ("t{0}_s{1}.log" -f $t, $s)
    Write-Host ("[REG] TEST={0} SEED={1}" -f $t, $s)
    $st = Run-One `
      -VvpExe $Vvp `
      -Sim $SimExe `
      -TestId $t `
      -Seed $s `
      -UseRandMem $RandMem `
      -BpPct $RandBpPct `
      -IMax $RandIMax `
      -DMax $RandDMax `
      -AsrtEn $AssertEn `
      -Swdog $StallWdog `
      -RwDog $RdWdog `
      -Mcycles $MaxCycles `
      -Extra $ExtraPlusarg `
      -LogPath $log
    $rows += [pscustomobject]@{
      Test   = $t
      Seed   = $s
      Status = $st
      Log    = $log
    }
    Write-Host ("[REG] -> {0}" -f $st)
  }
}

$csvPath = Join-Path $OutDir "summary.csv"
$txtPath = Join-Path $OutDir "summary.txt"
$rows | Export-Csv -NoTypeInformation -Path $csvPath

$total = @($rows).Count
$passN = @($rows | Where-Object { $_.Status -eq "PASS" }).Count
$failN = $total - $passN
$dur = (Get-Date) - $startTs

$summary = @()
$summary += ("Total: {0}" -f $total)
$summary += ("Pass : {0}" -f $passN)
$summary += ("Fail : {0}" -f $failN)
$summary += ("Time : {0}" -f $dur)
$summary += ("CSV  : {0}" -f $csvPath)
$summary += ("Mode : RAND_MEM={0} ASSERT_EN={1}" -f $RandMem, $AssertEn)

if ($failN -gt 0) {
  $summary += ""
  $summary += "Failed cases:"
  foreach ($r in @($rows | Where-Object { $_.Status -eq "FAIL" })) {
    $summary += ("  TEST={0} SEED={1} LOG={2}" -f $r.Test, $r.Seed, $r.Log)
  }
}

$summary | Set-Content -Path $txtPath
$summary | ForEach-Object { Write-Host $_ }

if ($failN -gt 0) {
  exit 1
}
exit 0
