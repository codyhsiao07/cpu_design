param(
  [string]$FreeRTOSRoot = "C:\Users\a0968\Downloads\FreeRTOSv202406.04-LTS\FreeRTOS-LTS\FreeRTOS\FreeRTOS-Kernel",
  [string]$BuildDir = "build_rtos",
  [string]$OutName = "rtos_smoke",
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

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$buildPath = Join-Path $repoRoot $BuildDir
$kernel = (Resolve-Path $FreeRTOSRoot).Path
$portDir = Join-Path $kernel "portable\GCC\RISC-V"
$chipExtDir = Join-Path $portDir "chip_specific_extensions\RV32I_CLINT_no_extensions"

$required = @(
  (Join-Path $kernel "include\FreeRTOS.h"),
  (Join-Path $kernel "tasks.c"),
  (Join-Path $kernel "queue.c"),
  (Join-Path $kernel "list.c"),
  (Join-Path $portDir "port.c"),
  (Join-Path $portDir "portASM.S"),
  (Join-Path $chipExtDir "freertos_risc_v_chip_specific_extensions.h"),
  (Join-Path $repoRoot "OS\rtos\config\FreeRTOSConfig.h"),
  (Join-Path $repoRoot "OS\rtos\link_ddr.ld"),
  (Join-Path $repoRoot "tools\bin_to_mem.py")
)
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

$sources = @(
  (Join-Path $repoRoot "OS\rtos\src\startup.S"),
  (Join-Path $repoRoot "OS\rtos\src\main.c"),
  (Join-Path $repoRoot "OS\rtos\src\uart.c"),
  (Join-Path $repoRoot "OS\rtos\src\freertos_hooks.c"),
  (Join-Path $repoRoot "OS\rtos\src\minilibc.c"),
  (Join-Path $kernel "list.c"),
  (Join-Path $kernel "queue.c"),
  (Join-Path $kernel "tasks.c"),
  (Join-Path $portDir "port.c"),
  (Join-Path $portDir "portASM.S")
)

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
  "-I$(Join-Path $kernel 'include')",
  "-I$portDir",
  "-I$chipExtDir",
  "-Wl,-T,$(Join-Path $repoRoot 'OS\rtos\link_ddr.ld')",
  "-Wl,-Map,$map",
  "-Wl,--no-relax",
  "-o", $elf
) + $sources + @(
  "-lgcc"
)

& $gcc @gccArgs
if ($LASTEXITCODE -ne 0) {
  throw "gcc failed"
}

& $objcopy -O binary $elf $bin
if ($LASTEXITCODE -ne 0) {
  throw "objcopy failed"
}

& $objdump -D $elf | Set-Content -Path $dis -Encoding ascii
if ($LASTEXITCODE -ne 0) {
  throw "objdump failed"
}

& python (Join-Path $repoRoot "tools\bin_to_mem.py") $bin $mem
if ($LASTEXITCODE -ne 0) {
  throw "bin_to_mem failed"
}

Write-Output "ELF: $elf"
Write-Output "BIN: $bin"
Write-Output "MEM: $mem"
Write-Output "DIS: $dis"
Write-Output "MAP: $map"
