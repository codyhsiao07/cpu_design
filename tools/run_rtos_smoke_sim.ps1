param(
  [string]$FreeRTOSRoot = "C:\Users\a0968\Downloads\FreeRTOSv202406.04-LTS\FreeRTOS-LTS\FreeRTOS\FreeRTOS-Kernel",
  [string]$BuildDir = "build_rtos",
  [string]$Iverilog = "iverilog",
  [string]$Vvp = "vvp",
  [int]$SkipBuild = 0,
  [int]$MaxCycles = 5000000,
  [uint32]$CpuClockHz = 100000000
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$buildPath = Join-Path $repoRoot $BuildDir
$simExe = Join-Path $buildPath "icache_pipeline_tb.out"
$mem = Join-Path $buildPath "rtos_smoke.mem"
$log = Join-Path $buildPath "rtos_smoke_sim.log"

New-Item -ItemType Directory -Path $buildPath -Force | Out-Null

if ($SkipBuild -eq 0) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "tools\build_rtos_smoke.ps1") `
    -FreeRTOSRoot $FreeRTOSRoot `
    -BuildDir $BuildDir `
    -CpuClockHz $CpuClockHz
  if ($LASTEXITCODE -ne 0) {
    throw "RTOS build failed"
  }
}

if (-not (Test-Path -LiteralPath $mem)) {
  throw "MEM file not found: $mem"
}

$rtl = Get-ChildItem -LiteralPath $repoRoot -Filter "*.v" -File | ForEach-Object { $_.FullName }
Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
& $Iverilog "-g2005-sv" "-DFAST_SIM" "-i" "-Picache_pipeline_tb.USE_MIG=0" "-Picache_pipeline_tb.RESET_PC=32'h80000000" "-Picache_pipeline_tb.MEM_WORDS=131072" "-o" $simExe "-s" "icache_pipeline_tb" @rtl
if ($LASTEXITCODE -ne 0) {
  throw "iverilog failed"
}

$plusArgs = @(
  "+TEST=0",
  "+MEMFILE=$mem",
  "+ASSERT_EN=1",
  "+MAXCYCLES=$MaxCycles",
  "+RTOS_UART_MON=1",
  "+RTOS_UART_FINISH_ON_PASS=1"
)

$lines = & $Vvp $simExe @plusArgs 2>&1
$simExitCode = $LASTEXITCODE
$lines | Tee-Object -FilePath $log
if ($simExitCode -ne 0) { throw "vvp failed: exit $simExitCode. Log: $log" }

$text = $lines -join "`n"
if ($text -notmatch "RTOS_SMOKE_PASS") {
  throw "RTOS smoke simulation did not observe RTOS_SMOKE_PASS. Log: $log"
}
if ($text -match "ASSERT_FAIL|FATAL|FAIL|TIMEOUT") {
  throw "RTOS smoke simulation saw a failure marker. Log: $log"
}

Write-Output "PASS: RTOS smoke simulation"
Write-Output "Log: $log"
