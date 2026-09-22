param(
  [string]$FreeRTOSRoot = "C:\Users\a0968\Downloads\FreeRTOSv202406.04-LTS\FreeRTOS-LTS\FreeRTOS\FreeRTOS-Kernel",
  [string]$BuildDir = "build_rtos_console_sim",
  [string]$Iverilog = "iverilog",
  [string]$Vvp = "vvp",
  [int]$MaxCycles = 5000000,
  [uint32]$CpuClockHz = 100000000
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$buildPath = Join-Path $repoRoot $BuildDir
$simExe = Join-Path $buildPath "icache_pipeline_console_tb.out"
$mem = Join-Path $buildPath "rtos_console.mem"
$log = Join-Path $buildPath "rtos_console_sim.log"

New-Item -ItemType Directory -Path $buildPath -Force | Out-Null
& (Join-Path $PSScriptRoot "build_rtos_app.ps1") `
  -App console `
  -FreeRTOSRoot $FreeRTOSRoot `
  -BuildDir $BuildDir `
  -OutName rtos_console `
  -CpuClockHz $CpuClockHz
if ($LASTEXITCODE -ne 0) { throw "RTOS Console build failed" }

$rtl = Get-ChildItem -LiteralPath $repoRoot -Filter "*.v" -File | ForEach-Object { $_.FullName }
Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
& $Iverilog "-g2005-sv" "-DFAST_SIM" "-i" `
  "-Picache_pipeline_tb.USE_MIG=0" `
  "-Picache_pipeline_tb.RESET_PC=32'h80000000" `
  "-Picache_pipeline_tb.MEM_WORDS=131072" `
  "-o" $simExe "-s" "icache_pipeline_tb" @rtl
if ($LASTEXITCODE -ne 0) { throw "iverilog failed" }

$lines = & $Vvp $simExe `
  "+TEST=0" `
  "+MEMFILE=$mem" `
  "+ASSERT_EN=1" `
  "+MAXCYCLES=$MaxCycles" `
  "+RTOS_UART_MON=1" `
  "+RTOS_UART_FINISH_ON_PASS=1" 2>&1
$simExitCode = $LASTEXITCODE
$lines | Tee-Object -FilePath $log
if ($simExitCode -ne 0) { throw "vvp failed: exit $simExitCode. Log: $log" }

$text = $lines -join "`n"
if ($text -notmatch "APP_READY") {
  throw "Simulation did not observe APP_READY. Log: $log"
}
if ($text -match "ASSERT_FAIL|FATAL|\[CONSOLE\] fatal|\[TRAP\]|TIMEOUT") {
  throw "Simulation saw a failure marker. Log: $log"
}

Write-Output "PASS: RTOS Console simulation"
Write-Output "Log: $log"
