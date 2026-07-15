param(
  [Parameter(Mandatory = $true)]
  [string]$Port,

  [string]$App = "",
  [string]$Mem = "",
  [string]$MainSource = "",
  [string[]]$ExtraSource = @(),
  [string]$BuildDir = "",
  [string]$OutName = "",
  [string]$PreflightMem = "",
  [string]$FreeRTOSRoot = "C:\Users\a0968\Downloads\FreeRTOSv202406.04-LTS\FreeRTOS-LTS\FreeRTOS\FreeRTOS-Kernel",
  [string]$ToolchainBin = "C:\riscv\xpack-riscv-none-elf-gcc\bin",
  [string]$Arch = "rv32im_zicsr",
  [uint32]$CpuClockHz = 50000000,
  [int]$Baud = 115200,
  [ValidateRange(0, 1048576)]
  [int]$Preamble = 4096,
  [ValidateSet("v1", "v2")]
  [string]$Protocol = "v2",
  [ValidateRange(1, 4096)]
  [int]$ChunkSize = 32,
  [ValidateRange(0.0, 1.0)]
  [double]$ChunkDelay = 0.001,
  [ValidateRange(0.0, 1.0)]
  [double]$SyncSettle = 0.02,
  [ValidateRange(0.0, 1.0)]
  [double]$HeaderSettle = 0.005,
  [ValidateRange(0.1, 30.0)]
  [double]$BootAckTimeout = 2.0,
  [double]$StartupDelay = 5.0,
  [double]$PreflightTimeout = 20.0,
  [ValidateRange(1, 5)]
  [int]$PreflightAttempts = 5,
  [double]$TargetDelay = 5.0,
  [string]$TargetMarker = "",
  [double]$TargetTimeout = 20.0,
  [ValidateRange(1, 5)]
  [int]$TargetAttempts = 5,
  [ValidateSet("interactive", "listen", "none")]
  [string]$Monitor = "interactive",
  [double]$ListenSeconds = 5.0,
  [string]$Log = "",
  [switch]$SkipAutoReload,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$buildScript = Join-Path $PSScriptRoot "build_rtos_app.ps1"
$runner = Join-Path $PSScriptRoot "rtos_board_runner.py"

function Resolve-WorkspaceFile([string]$PathValue) {
  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return (Resolve-Path -LiteralPath $PathValue).Path
  }
  return (Resolve-Path -LiteralPath (Join-Path $repoRoot $PathValue)).Path
}

if (-not [string]::IsNullOrWhiteSpace($Mem) -and -not [string]::IsNullOrWhiteSpace($App)) {
  throw "Choose one target: use either -Mem for an existing image or -App for a build profile."
}
if ([string]::IsNullOrWhiteSpace($Mem) -and [string]::IsNullOrWhiteSpace($App)) {
  if (-not [string]::IsNullOrWhiteSpace($MainSource)) {
    $App = "custom"
  } else {
    throw "No target selected. Use -App smoke (or another profile), or -Mem path\to\app.mem."
  }
}

if ([string]::IsNullOrWhiteSpace($PreflightMem)) {
  $preflightBuildDir = "build_rtos_apps\preflight"
  & $buildScript `
    -App preflight `
    -BuildDir $preflightBuildDir `
    -OutName rtos_preflight `
    -FreeRTOSRoot $FreeRTOSRoot `
    -ToolchainBin $ToolchainBin `
    -Arch $Arch `
    -CpuClockHz $CpuClockHz
  if ($LASTEXITCODE -ne 0) { throw "Preflight build failed." }
  $preflightPath = Join-Path $repoRoot "$preflightBuildDir\rtos_preflight.mem"
} else {
  $preflightPath = Resolve-WorkspaceFile $PreflightMem
}

if (-not [string]::IsNullOrWhiteSpace($Mem)) {
  $targetPath = Resolve-WorkspaceFile $Mem
} else {
  if ([string]::IsNullOrWhiteSpace($BuildDir)) {
    $BuildDir = "build_rtos_apps\$App"
  }
  if ([string]::IsNullOrWhiteSpace($OutName)) {
    $OutName = "rtos_$($App -replace '[^A-Za-z0-9_]', '_')"
  }

  $buildArgs = @{
    App = $App
    BuildDir = $BuildDir
    OutName = $OutName
    FreeRTOSRoot = $FreeRTOSRoot
    ToolchainBin = $ToolchainBin
    Arch = $Arch
    CpuClockHz = $CpuClockHz
  }
  if (-not [string]::IsNullOrWhiteSpace($MainSource)) {
    $buildArgs.MainSource = $MainSource
  }
  if ($ExtraSource.Count -gt 0) {
    $buildArgs.ExtraSource = $ExtraSource
  }
  & $buildScript @buildArgs
  if ($LASTEXITCODE -ne 0) { throw "Target app build failed." }
  $targetPath = Join-Path $repoRoot "$BuildDir\$OutName.mem"
}

if ([string]::IsNullOrWhiteSpace($TargetMarker)) {
  $targetName = [System.IO.Path]::GetFileNameWithoutExtension($targetPath).ToLowerInvariant()
  if (($App -eq "smoke") -or ($targetName -match "rtos_smoke")) {
    $TargetMarker = "RTOS_SMOKE_PASS"
  } elseif (($App -eq "console") -or ($targetName -match "rtos_console")) {
    $TargetMarker = "APP_READY"
  } elseif (($App -eq "platform") -or ($targetName -match "rtos_platform")) {
    $TargetMarker = "RTOS_PLATFORM_PASS"
  } elseif (($App -eq "lua") -or ($targetName -match "rtos_lua")) {
    $TargetMarker = "LUA_RTOS_READY"
  } elseif (($App -eq "vga_demo") -or ($targetName -match "vga_demo")) {
    $TargetMarker = "[VGA] task=L start"
  } elseif (($App -eq "vga_queue_demo") -or ($targetName -match "vga_queue")) {
    $TargetMarker = "[PIPE] task=P producer start"
  }
}

# The Lua VM performs parser, floating-point, allocator and recovery self-tests
# on the 50 MHz board before announcing readiness. Its normal boot can exceed
# the generic 20-second application timeout.
if (($App -eq "lua") -and (-not $PSBoundParameters.ContainsKey("TargetTimeout"))) {
  $TargetTimeout = 60.0
}
$python = Get-Command python -ErrorAction Stop
$runnerArgs = @(
  $runner,
  "--port", $Port,
  "--baud", $Baud,
  "--preflight-mem", $preflightPath,
  "--target-mem", $targetPath,
  "--startup-delay", $StartupDelay,
  "--target-delay", $TargetDelay,
  "--preflight-timeout", $PreflightTimeout,
  "--preflight-attempts", $PreflightAttempts,
  "--target-timeout", $TargetTimeout,
  "--target-attempts", $TargetAttempts,
  "--preamble", $Preamble,
  "--protocol", $Protocol,
  "--chunk-size", $ChunkSize,
  "--chunk-delay", $ChunkDelay,
  "--sync-settle", $SyncSettle,
  "--header-settle", $HeaderSettle,
  "--boot-ack-timeout", $BootAckTimeout,
  "--monitor", $Monitor,
  "--listen-seconds", $ListenSeconds
)
if (-not [string]::IsNullOrWhiteSpace($TargetMarker)) {
  $runnerArgs += @("--target-marker", $TargetMarker)
}
if (-not [string]::IsNullOrWhiteSpace($Log)) {
  $runnerArgs += @("--log", $Log)
}
if ($SkipAutoReload) {
  $runnerArgs += "--skip-auto-reload"
}
if ($DryRun) {
  $runnerArgs += "--dry-run"
}

Write-Output "RTOS target: $targetPath"
& $python.Source @runnerArgs
if ($LASTEXITCODE -ne 0) {
  throw "RTOS board runner failed with exit code $LASTEXITCODE."
}
