param(
  [string]$App = "smoke",
  [string]$MainSource = "",
  [string[]]$ExtraSource = @(),
  [string]$FreeRTOSRoot = "C:\Users\a0968\Downloads\FreeRTOSv202406.04-LTS\FreeRTOS-LTS\FreeRTOS\FreeRTOS-Kernel",
  [string]$BuildDir = "",
  [string]$OutName = "",
  [string]$ToolchainBin = "C:\riscv\xpack-riscv-none-elf-gcc\bin",
  [string]$Arch = "rv32im_zicsr",
  [uint32]$CpuClockHz = 50000000
)

$ErrorActionPreference = "Stop"

function Find-Tool([string[]]$Candidates) {
  foreach ($tool in $Candidates) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($cmd) {
      return $cmd.Source
    }
  }
  return $null
}

function Resolve-RepoFile([string]$PathValue) {
  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return (Resolve-Path -LiteralPath $PathValue).Path
  }
  return (Resolve-Path -LiteralPath (Join-Path $repoRoot $PathValue)).Path
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$profiles = @{
  "smoke" = @{
    Main = "OS\rtos\src\main.c"
    Extra = @()
  }
  "preflight" = @{
    Main = "OS\rtos\src\main_preflight.c"
    Extra = @("OS\rtos\src\board_control.c")
  }
  "console" = @{
    Main = "OS\rtos\src\main_console.c"
    Extra = @("OS\rtos\src\board_control.c")
  }
  "vga_demo" = @{
    Main = "OS\rtos\src\main_vga_demo.c"
    Extra = @("game\vga_fb.c")
  }
  "vga_queue_demo" = @{
    Main = "OS\rtos\src\main_vga_queue_demo.c"
    Extra = @("game\vga_fb.c")
  }
}

if ([string]::IsNullOrWhiteSpace($MainSource)) {
  if (-not $profiles.ContainsKey($App)) {
    $known = ($profiles.Keys | Sort-Object) -join ", "
    throw "Unknown RTOS app '$App'. Known profiles: $known. For a custom app, also pass -MainSource."
  }
  $main = Resolve-RepoFile $profiles[$App].Main
  $profileExtra = @($profiles[$App].Extra | ForEach-Object { Resolve-RepoFile $_ })
} else {
  $main = Resolve-RepoFile $MainSource
  $profileExtra = @()
}

$userExtra = @($ExtraSource | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Resolve-RepoFile $_ })

if ([string]::IsNullOrWhiteSpace($OutName)) {
  $OutName = "rtos_$($App -replace '[^A-Za-z0-9_]', '_')"
}
if ([string]::IsNullOrWhiteSpace($BuildDir)) {
  $BuildDir = Join-Path "build_rtos_apps" $App
}

$buildPath = Join-Path $repoRoot $BuildDir
$kernel = (Resolve-Path -LiteralPath $FreeRTOSRoot).Path
$portDir = Join-Path $kernel "portable\GCC\RISC-V"
$chipExtDir = Join-Path $portDir "chip_specific_extensions\RV32I_CLINT_no_extensions"

$sources = @(
  (Join-Path $repoRoot "OS\rtos\src\startup.S"),
  $main,
  (Join-Path $repoRoot "OS\rtos\src\uart.c"),
  (Join-Path $repoRoot "OS\rtos\src\freertos_hooks.c"),
  (Join-Path $repoRoot "OS\rtos\src\minilibc.c")
) + $profileExtra + $userExtra + @(
  (Join-Path $kernel "list.c"),
  (Join-Path $kernel "queue.c"),
  (Join-Path $kernel "tasks.c"),
  (Join-Path $portDir "port.c"),
  (Join-Path $portDir "portASM.S")
)

$required = @(
  (Join-Path $kernel "include\FreeRTOS.h"),
  (Join-Path $chipExtDir "freertos_risc_v_chip_specific_extensions.h"),
  (Join-Path $repoRoot "OS\rtos\config\FreeRTOSConfig.h"),
  (Join-Path $repoRoot "OS\rtos\link_ddr.ld"),
  (Join-Path $repoRoot "tools\bin_to_mem.py")
) + $sources
foreach ($path in $required) {
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Required file not found: $path"
  }
}

if (Test-Path -LiteralPath $ToolchainBin) {
  $env:PATH = "$ToolchainBin;$env:PATH"
}

$gcc = Find-Tool @("riscv-none-elf-gcc", "riscv32-unknown-elf-gcc", "riscv64-unknown-elf-gcc")
$objcopy = Find-Tool @("riscv-none-elf-objcopy", "riscv32-unknown-elf-objcopy", "riscv64-unknown-elf-objcopy")
$objdump = Find-Tool @("riscv-none-elf-objdump", "riscv32-unknown-elf-objdump", "riscv64-unknown-elf-objdump")
if (-not $gcc -or -not $objcopy -or -not $objdump) {
  throw "RISC-V toolchain not found. Tried ToolchainBin=$ToolchainBin and PATH."
}

New-Item -ItemType Directory -Path $buildPath -Force | Out-Null
$elf = Join-Path $buildPath "$OutName.elf"
$bin = Join-Path $buildPath "$OutName.bin"
$mem = Join-Path $buildPath "$OutName.mem"
$dis = Join-Path $buildPath "$OutName.dis"
$map = Join-Path $buildPath "$OutName.map"

$gccArgs = @(
  "-march=$Arch",
  "-DconfigCPU_CLOCK_HZ=$($CpuClockHz)UL",
  "-mabi=ilp32",
  "-mno-relax",
  "-ffreestanding",
  "-nostdlib",
  "-O2",
  "-Wall",
  "-Wextra",
  "-Wno-unused-parameter",
  "-I$(Join-Path $repoRoot 'OS\rtos\config')",
  "-I$(Join-Path $repoRoot 'OS\rtos\src')",
  "-I$(Join-Path $repoRoot 'game')",
  "-I$(Join-Path $kernel 'include')",
  "-I$portDir",
  "-I$chipExtDir",
  "-Wl,-T,$(Join-Path $repoRoot 'OS\rtos\link_ddr.ld')",
  "-Wl,-Map,$map",
  "-Wl,--no-relax",
  "-o", $elf
) + $sources + @("-lgcc")

& $gcc @gccArgs
if ($LASTEXITCODE -ne 0) { throw "gcc failed" }
& $objcopy -O binary $elf $bin
if ($LASTEXITCODE -ne 0) { throw "objcopy failed" }
& $objdump -D $elf | Set-Content -Path $dis -Encoding ascii
if ($LASTEXITCODE -ne 0) { throw "objdump failed" }
& python (Join-Path $repoRoot "tools\bin_to_mem.py") $bin $mem
if ($LASTEXITCODE -ne 0) { throw "bin_to_mem failed" }

Write-Output "APP: $App"
Write-Output "ELF: $elf"
Write-Output "MEM: $mem"
Write-Output "DIS: $dis"
Write-Output "MAP: $map"
