param(
  [string]$Source = "TEST_FILES/prog_test22_from_c.c",
  [string]$OutMem = "TEST_FILES/mem_test22_from_c.mem",
  [string]$BuildDir = "build_rv32",
  [string]$Linker = "tools/link_ddr.ld",
  [string]$Crt0 = "tools/crt0.S",
  [string[]]$ExtraSources = @(),
  [string]$Arch = "rv32im_zicsr",
  [string]$ToolchainBin = "C:\\riscv\\xpack-riscv-none-elf-gcc\\bin"
)

$ErrorActionPreference = "Stop"

function Find-Tool([string[]]$candidates) {
  foreach ($t in $candidates) {
    $cmd = Get-Command $t -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  return $null
}

if (Test-Path $ToolchainBin) {
  $env:PATH = "$ToolchainBin;$env:PATH"
}

$gcc = Find-Tool @(
  "riscv-none-elf-gcc",
  "riscv32-unknown-elf-gcc",
  "riscv64-unknown-elf-gcc",
  "riscv32-elf-gcc",
  "riscv64-elf-gcc"
)

$objcopy = Find-Tool @(
  "riscv-none-elf-objcopy",
  "riscv32-unknown-elf-objcopy",
  "riscv64-unknown-elf-objcopy",
  "riscv32-elf-objcopy",
  "riscv64-elf-objcopy"
)

if (-not $gcc -or -not $objcopy) {
  Write-Error "RISC-V toolchain not found. Need gcc+objcopy (riscv*-unknown-elf-*). Tried ToolchainBin=$ToolchainBin."
}

New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null

$stem = [System.IO.Path]::GetFileNameWithoutExtension($Source)
if ([string]::IsNullOrWhiteSpace($stem)) {
  $stem = "prog"
}
$elf = Join-Path $BuildDir ("{0}.elf" -f $stem)
$bin = Join-Path $BuildDir ("{0}.bin" -f $stem)

$sourceList = @($Crt0)
if ($ExtraSources) {
  $sourceList += $ExtraSources
}
$sourceList += $Source

$gccArgs = @(
  "-march=$Arch",
  "-mabi=ilp32",
  "-ffreestanding",
  "-nostdlib",
  "-O2",
  "-Wl,-T,$Linker",
  "-o", $elf
) + $sourceList

& $gcc @gccArgs
if ($LASTEXITCODE -ne 0) {
  throw "gcc failed"
}

& $objcopy -O binary $elf $bin
if ($LASTEXITCODE -ne 0) {
  throw "objcopy failed"
}

& python tools/bin_to_mem.py $bin $OutMem
if ($LASTEXITCODE -ne 0) {
  throw "bin_to_mem failed"
}

Write-Output "Done: $OutMem"
